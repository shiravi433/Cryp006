// TokenStore stores Tokens for applications, which have discrete States increasing with time
pragma solidity ^0.5.0;

import "@gnosis.pm/mock-contract/contracts/MockContract.sol";
import "../IntervalTokenStore.sol";


contract IntervalTokenStoreTestInterface is IntervalTokenStore {


    function increaseStateIndex() public {
        currentStateIndex++;
    }

    function addBalanceTest(address user, address token, uint amount) public {
        super.addBalance(user, token, amount);
    }

    function substractBalanceTest(address user, address token, uint amount) public {
        super.substractBalance(user, token, amount);
    }
}