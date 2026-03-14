// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {FundablePoll} from "./FundablePoll.sol";

contract FundablePollFactory {
    string private constant FACTORY_VERSION = "1.0.0";

    address[] private _allPolls;
    mapping(address => address[]) private _pollsByCreator;

    event PollDeployed(
        address indexed pollCreator,
        address indexed pollAddress,
        address indexed votingToken,
        uint64 startTime,
        uint64 endTime,
        uint256 tokensPerVote,
        uint256 winningOptionsCount,
        uint256 totalOptions
    );

    function deployPoll(
        uint64 startTime,
        uint64 endTime,
        address votingToken,
        uint256 tokensPerVote,
        uint256 winningOptionsCount,
        uint256 totalOptions
    ) external returns (address pollAddress) {
        FundablePoll poll = new FundablePoll(
            address(this),
            msg.sender,
            startTime,
            endTime,
            votingToken,
            tokensPerVote,
            winningOptionsCount,
            totalOptions
        );

        pollAddress = address(poll);
        _allPolls.push(pollAddress);
        _pollsByCreator[msg.sender].push(pollAddress);

        emit PollDeployed(
            msg.sender, pollAddress, votingToken, startTime, endTime, tokensPerVote, winningOptionsCount, totalOptions
        );
    }

    function version() external pure returns (string memory) {
        return FACTORY_VERSION;
    }

    function pollsCount() external view returns (uint256) {
        return _allPolls.length;
    }

    function allPolls(uint256 index) external view returns (address) {
        return _allPolls[index];
    }

    function pollsByCreator(address creator) external view returns (address[] memory) {
        return _pollsByCreator[creator];
    }
}
