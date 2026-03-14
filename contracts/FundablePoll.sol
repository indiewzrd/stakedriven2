// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

error TokenTransferFailed();
error TokenBalanceQueryFailed();

library SafeTokenTransfer {
    function safeTransfer(IERC20Minimal token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenTransferFailed();
    }

    function safeTransferFrom(IERC20Minimal token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, amount));
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) revert TokenTransferFailed();
    }

    function safeBalanceOf(IERC20Minimal token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeWithSelector(token.balanceOf.selector, account));
        if (!success || data.length < 32) revert TokenBalanceQueryFailed();
        return abi.decode(data, (uint256));
    }
}

contract FundablePoll {
    using SafeTokenTransfer for IERC20Minimal;

    error InvalidPollConfiguration();
    error PollNotActive();
    error PollStillActive();
    error InvalidOptionNumber();
    error WalletAlreadyVoted();
    error WalletHasNoActiveVote();
    error VoteIsWinningOption();
    error NotPollCreator();
    error WinningFundsAlreadyClaimed();
    error ReentrancyDetected();
    error UnsupportedVotingToken();

    uint256 public constant MAX_OPTIONS = 100;

    uint64 public immutable startTime;
    uint64 public immutable endTime;
    address public immutable votingToken;
    uint256 public immutable tokensPerVote;
    uint256 public immutable winningOptionsCount;
    uint256 public immutable totalOptions;
    address public immutable pollCreator;
    address public immutable factory;

    bool public finalized;
    bool public winningFundsClaimed;
    uint256 public totalWinningFunds;

    mapping(address => uint256) private _voterOptionByWallet;
    mapping(address => uint256) private _voterStakeByWallet;
    uint256[] private _optionFunds;
    mapping(uint256 => bool) private _isWinningOptionByNumber;
    uint256[] private _winningOptionNumbers;
    uint256 private _totalOutstandingFunds;

    uint256 private _reentrancyLock = 1;

    event VoteCast(address indexed voter, uint256 indexed optionNumber, uint256 amount);
    event VoteCancelled(address indexed voter, uint256 indexed optionNumber, uint256 amount);
    event NonWinningFundsClaimed(address indexed voter, uint256 indexed optionNumber, uint256 amount);
    event PollFinalized(uint256[] winningOptionNumbers, uint256 totalWinningFunds, bytes32 tieBreakSeed);
    event WinningFundsClaimed(address indexed pollCreator, uint256 amount);

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert ReentrancyDetected();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    constructor(
        address factory_,
        address pollCreator_,
        uint64 startTime_,
        uint64 endTime_,
        address votingToken_,
        uint256 tokensPerVote_,
        uint256 winningOptionsCount_,
        uint256 totalOptions_
    ) {
        if (
            factory_ == address(0) || pollCreator_ == address(0) || votingToken_ == address(0)
                || endTime_ <= startTime_ || endTime_ <= block.timestamp || tokensPerVote_ == 0 || totalOptions_ == 0
                || totalOptions_ > MAX_OPTIONS || winningOptionsCount_ == 0 || winningOptionsCount_ > totalOptions_
        ) {
            revert InvalidPollConfiguration();
        }
        if (votingToken_.code.length == 0) revert UnsupportedVotingToken();

        factory = factory_;
        pollCreator = pollCreator_;
        startTime = startTime_;
        endTime = endTime_;
        votingToken = votingToken_;
        tokensPerVote = tokensPerVote_;
        winningOptionsCount = winningOptionsCount_;
        totalOptions = totalOptions_;

        _optionFunds = new uint256[](totalOptions_);
    }

    function vote(uint256 optionNumber) external nonReentrant {
        _requireActivePoll();
        _validateOption(optionNumber);
        if (_voterOptionByWallet[msg.sender] != 0) revert WalletAlreadyVoted();

        uint256 balanceBefore = IERC20Minimal(votingToken).safeBalanceOf(address(this));
        IERC20Minimal(votingToken).safeTransferFrom(msg.sender, address(this), tokensPerVote);
        uint256 balanceAfter = IERC20Minimal(votingToken).safeBalanceOf(address(this));
        uint256 receivedAmount = balanceAfter - balanceBefore;
        if (receivedAmount == 0) revert TokenTransferFailed();

        _voterOptionByWallet[msg.sender] = optionNumber;
        _voterStakeByWallet[msg.sender] = receivedAmount;
        _optionFunds[optionNumber - 1] += receivedAmount;
        _totalOutstandingFunds += receivedAmount;

        emit VoteCast(msg.sender, optionNumber, receivedAmount);
    }

    function cancelVote() external nonReentrant {
        _requireActivePoll();
        uint256 optionNumber = _voterOptionByWallet[msg.sender];
        if (optionNumber == 0) revert WalletHasNoActiveVote();
        uint256 stakeAmount = _voterStakeByWallet[msg.sender];
        uint256 payoutAmount = _calculatePayout(stakeAmount);

        _voterOptionByWallet[msg.sender] = 0;
        _voterStakeByWallet[msg.sender] = 0;
        _optionFunds[optionNumber - 1] -= stakeAmount;
        _totalOutstandingFunds -= stakeAmount;

        IERC20Minimal(votingToken).safeTransfer(msg.sender, payoutAmount);

        emit VoteCancelled(msg.sender, optionNumber, payoutAmount);
    }

    function claimNonWinningFunds() external nonReentrant {
        _requireEndedPoll();
        uint256 optionNumber = _voterOptionByWallet[msg.sender];
        if (optionNumber == 0) revert WalletHasNoActiveVote();
        uint256 stakeAmount = _voterStakeByWallet[msg.sender];

        _finalizeIfNeeded();
        if (_isWinningOptionByNumber[optionNumber]) revert VoteIsWinningOption();
        uint256 payoutAmount = _calculatePayout(stakeAmount);

        _voterOptionByWallet[msg.sender] = 0;
        _voterStakeByWallet[msg.sender] = 0;
        _totalOutstandingFunds -= stakeAmount;
        IERC20Minimal(votingToken).safeTransfer(msg.sender, payoutAmount);

        emit NonWinningFundsClaimed(msg.sender, optionNumber, payoutAmount);
    }

    function claimWinningOptionsFunds() external nonReentrant {
        if (msg.sender != pollCreator) revert NotPollCreator();
        _requireEndedPoll();
        _finalizeIfNeeded();
        if (winningFundsClaimed) revert WinningFundsAlreadyClaimed();

        uint256 payoutAmount = _calculatePayout(totalWinningFunds);
        winningFundsClaimed = true;
        _totalOutstandingFunds -= totalWinningFunds;
        IERC20Minimal(votingToken).safeTransfer(msg.sender, payoutAmount);

        emit WinningFundsClaimed(msg.sender, payoutAmount);
    }

    function finalizePoll() external {
        _requireEndedPoll();
        _finalizeIfNeeded();
    }

    function currentVotingResults() external view returns (uint256[] memory) {
        return _optionFunds;
    }

    function votingOptionNumberOf(address wallet) external view returns (uint256) {
        return _voterOptionByWallet[wallet];
    }

    function winningOptionNumbers() external view returns (uint256[] memory) {
        return _winningOptionNumbers;
    }

    function isWinningOption(uint256 optionNumber) external view returns (bool) {
        if (optionNumber == 0 || optionNumber > totalOptions) return false;
        return _isWinningOptionByNumber[optionNumber];
    }

    function _validateOption(uint256 optionNumber) internal view {
        if (optionNumber == 0 || optionNumber > totalOptions) revert InvalidOptionNumber();
    }

    function _requireActivePoll() internal view {
        if (block.timestamp < startTime || block.timestamp > endTime) revert PollNotActive();
    }

    function _requireEndedPoll() internal view {
        if (block.timestamp <= endTime) revert PollStillActive();
    }

    function _finalizeIfNeeded() internal {
        if (finalized) return;

        bytes32 tieBreakSeed = keccak256(
            abi.encodePacked(address(this), factory, pollCreator, startTime, endTime, totalOptions, winningOptionsCount)
        );

        uint256[] memory optionNumbers = new uint256[](totalOptions);
        uint256[] memory optionTieBreaks = new uint256[](totalOptions);
        for (uint256 i = 0; i < totalOptions; i++) {
            uint256 optionNumber = i + 1;
            optionNumbers[i] = optionNumber;
            optionTieBreaks[i] = uint256(keccak256(abi.encodePacked(tieBreakSeed, optionNumber)));
        }

        uint256[] memory winners = new uint256[](winningOptionsCount);
        uint256 winningFundsAccumulator;

        // Partial selection sort: only the top winningOptionsCount entries are selected.
        for (uint256 i = 0; i < winningOptionsCount; i++) {
            uint256 bestIndex = i;
            for (uint256 j = i + 1; j < totalOptions; j++) {
                if (_isHigherRank(optionNumbers[j], optionNumbers[bestIndex], optionTieBreaks)) {
                    bestIndex = j;
                }
            }

            if (bestIndex != i) {
                uint256 temp = optionNumbers[i];
                optionNumbers[i] = optionNumbers[bestIndex];
                optionNumbers[bestIndex] = temp;
            }

            uint256 winnerOptionNumber = optionNumbers[i];
            winners[i] = winnerOptionNumber;
            winningFundsAccumulator += _optionFunds[winnerOptionNumber - 1];
        }
        for (uint256 i = 0; i < winningOptionsCount; i++) {
            _isWinningOptionByNumber[winners[i]] = true;
        }
        _winningOptionNumbers = winners;

        finalized = true;
        totalWinningFunds = winningFundsAccumulator;

        emit PollFinalized(winners, winningFundsAccumulator, tieBreakSeed);
    }

    function _isHigherRank(uint256 optionA, uint256 optionB, uint256[] memory optionTieBreaks) internal view returns (bool) {
        uint256 fundsA = _optionFunds[optionA - 1];
        uint256 fundsB = _optionFunds[optionB - 1];

        if (fundsA != fundsB) return fundsA > fundsB;

        uint256 tieBreakA = optionTieBreaks[optionA - 1];
        uint256 tieBreakB = optionTieBreaks[optionB - 1];
        return tieBreakA > tieBreakB;
    }

    function _calculatePayout(uint256 liabilityAmount) internal view returns (uint256) {
        uint256 totalOutstandingFunds = _totalOutstandingFunds;
        if (liabilityAmount == 0 || totalOutstandingFunds == 0) return 0;

        uint256 currentBalance = IERC20Minimal(votingToken).safeBalanceOf(address(this));
        if (liabilityAmount == totalOutstandingFunds) return currentBalance;

        return (liabilityAmount * currentBalance) / totalOutstandingFunds;
    }
}
