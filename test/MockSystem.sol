// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// @title MockSystem — test double for the Reactive system contract.
/// @notice Etched onto 0x8888…8888 in tests so the reactive/vault contracts run
///         against a recorder instead of the real Lasna system contract.
contract MockSystem is ISystemContract {
    struct Subscription {
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    struct CallbackRequest {
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Subscription[] public subscriptions;
    CallbackRequest[] public callbackRequests;
    mapping(address => uint256) public reservesMap;

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function callbackRequestCount() external view returns (uint256) {
        return callbackRequests.length;
    }

    receive() external payable {}

    function debt(address) external view returns (uint256) {
        return 0;
    }

    function reserves(address contract_) external view returns (uint256) {
        return reservesMap[contract_];
    }

    function depositTo(address contract_) external payable {
        reservesMap[contract_] += msg.value;
    }

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        subscriptions.push(Subscription(chainId_, contract_, topic0_, topic1_, topic2_, topic3_));
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        for (uint256 i = 0; i < subscriptions.length; i++) {
            Subscription memory s = subscriptions[i];
            if (
                s.chainId == chainId_ && s.contractAddr == contract_ && s.topic0 == topic0_ && s.topic1 == topic1_
                    && s.topic2 == topic2_ && s.topic3 == topic3_
            ) {
                subscriptions[i] = subscriptions[subscriptions.length - 1];
                subscriptions.pop();
                return;
            }
        }
    }

    function requestCallback(CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(CallbackConfiguration_V_1_0 memory config_) external {
        callbackRequests.push(CallbackRequest(config_.chainId, config_.recipient, config_.gasLimit, config_.payload));
    }
}
