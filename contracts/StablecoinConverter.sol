pragma solidity ^0.5.0;

import "./EpochTokenLocker.sol";
import "@gnosis.pm/solidity-data-structures/contracts/libraries/IdToAddressBiMap.sol";
import "@gnosis.pm/solidity-data-structures/contracts/libraries/IterableAppendOnlySet.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";
import "./libraries/TokenConservation.sol";

/** @title Stable Coin Converter - A decentralized exchange for stable tokens as a batch auciton.
 * @author Alex Herrmann - <alex@gnosis.pm>
 * @author Benjamin Smith - <ben@gnosis.pm>
 * @author Felix Leupold - <felix@gnosis.pm>
 */
contract StablecoinConverter is EpochTokenLocker {
    using SafeMath for uint128;
    using BytesLib for bytes32;
    using BytesLib for bytes;
    using TokenConservation for int[];

    uint constant private MAX_UINT128 = 2**128 - 1;

    event OrderPlacement(
        address owner,
        uint16 buyToken,
        uint16 sellToken,
        bool isSellOrder,
        uint32 validFrom,
        uint32 validUntil,
        uint128 priceNumerator,
        uint128 priceDenominator
    );

    event OrderCancelation(
        address owner,
        uint id
    );

    struct Order {
        uint16 buyToken;
        uint16 sellToken;
        uint32 validFrom;   // order is valid from auction collection period: validFrom inclusive
        uint32 validUntil;  // order is valid till auction collection period: validUntil inclusive
        bool isSellOrder;
        uint128 priceNumerator;
        uint128 priceDenominator;
        uint128 remainingAmount; // remainingAmount can either be a sellAmount or buyAmount, depending on the flag isSellOrder
    }

    // User-> Order
    mapping(address => Order[]) public orders;

    // Iterable set of all users, required to collect auction information
    IterableAppendOnlySet.Data private allUsers;
    using IterableAppendOnlySet for IterableAppendOnlySet.Data;

    IdToAddressBiMap.Data private registeredTokens;

    uint public MAX_TOKENS;  // solhint-disable var-name-mixedcase
    uint16 public numTokens;
    uint128 public feeDenominator;

    /** @dev Constructor determines exchange parameters
      * @param maxTokens The maximum number of tokens that can be listed.
      * @param _feeDenominator fee as a proportion is (1 / feeDenominator)
      * @param feeToken Address of ERC20 fee token.
      */
    constructor(uint maxTokens, uint128 _feeDenominator, address feeToken) public {
        MAX_TOKENS = maxTokens;
        feeDenominator = _feeDenominator;
        addToken(feeToken); // fee Token will always have the token index 0
    }

    /** @dev Used to list a new token on the exchange.
      * @param _tokenAddress ERC20 token to be listed.
      */
    function addToken(address _tokenAddress) public {
        require(numTokens < MAX_TOKENS, "Max tokens reached");
        require(
            IdToAddressBiMap.insert(registeredTokens, numTokens, _tokenAddress),
            "Token already registered"
        );
        numTokens++;
    }

    /** @dev a user facing function used to place limit sell orders in auction with expiry defined by batchId
      * @param buyToken id of token to be bought
      * @param sellToken id of token to be sold
      * @param isSellOrder - TODO - remove with
      * @param validUntil - batchId represnting order's expiry
      * @param buyAmount - relative minimum amount of requested buy amount
      * @param sellAmount - maximum amount of sell token to be exchanged
      * @return orderId as index of user's current orders
      */
    function placeOrder(
        uint16 buyToken,
        uint16 sellToken,
        bool isSellOrder,
        uint32 validUntil,
        uint128 buyAmount,
        uint128 sellAmount
    ) public returns (uint) {
        orders[msg.sender].push(Order({
            buyToken: buyToken,
            sellToken: sellToken,
            validFrom: getCurrentBatchId(),
            validUntil: validUntil,
            isSellOrder: isSellOrder,
            priceNumerator: buyAmount,
            priceDenominator: sellAmount,
            remainingAmount: sellAmount
        }));
        emit OrderPlacement(
            msg.sender,
            buyToken,
            sellToken,
            isSellOrder,
            getCurrentBatchId(),
            validUntil,
            buyAmount,
            sellAmount
        );
        allUsers.insert(msg.sender);
        return orders[msg.sender].length - 1;
    }

    /** @dev a user facing function used to cancel orders (sets order expiry to previous batchId)
      * @param id referencing the index of user's order to be canceled
      */
    function cancelOrder(uint id) public {
        orders[msg.sender][id].validUntil = getCurrentBatchId() - 1;
        emit OrderCancelation(msg.sender, id);
    }

    /** @dev a user facing function used to delete expired orders
      * @param ids referencing the indices of user's orders to be deleted
      */
    function freeStorageOfOrder(uint[] memory ids) public {
        for (uint i = 0; i < ids.length; i++) {
            require(orders[msg.sender][ids[i]].validUntil + 1 < getCurrentBatchId(), "Order is still valid");
            delete orders[msg.sender][ids[i]];
        }
    }

    /**
     * Public View Methods
     */

    /** @dev View returning ID of listed tokens
      * @param addr address of listed token.
      * @return tokenId as stored, via BiMap, within the contract.
      */
    function tokenAddressToIdMap(address addr) public view returns (uint16) {
        return IdToAddressBiMap.getId(registeredTokens, addr);
    }

    /** @dev View returning address of listed token by ID
      * @param id tokenId as stored, via BiMap, within the contract.
      * @return address of (listed) token
      */
    function tokenIdToAddressMap(uint16 id) public view returns (address) {
        return IdToAddressBiMap.getAddressAt(registeredTokens, id);
    }

    /** @dev View returning all currently stored, byte-encoded sell orders
      * @return encoded bytes representing all orders ordered by (user, index)
      */
    function getEncodedAuctionElements() public view returns (bytes memory elements) {
        if (allUsers.size() > 0) {
            address user = allUsers.first();
            bool stop = false;
            while (!stop) {
                for (uint i = 0; i < orders[user].length; i++) {
                    Order memory order = orders[user][i];
                    elements = elements.concat(encodeAuctionElement(
                        user,
                        getBalance(user, tokenIdToAddressMap(order.sellToken)),
                        order
                    ));
                }
                if (user == allUsers.last) {
                    stop = true;
                } else {
                    user = allUsers.next(user);
                }
            }
        }
        return elements;
    }

    mapping (uint16 => uint128) public currentPrices;
    PreviousSolutionData public previousSolution;

    struct PreviousSolutionData {
        uint32 batchId;
        TradeData[] trades;
        uint16[] tokenIdsForPrice;
        address solutionSubmitter;
        uint256 feeReward;
        uint256 objectiveValue;
    }

    struct TradeData {
        address owner;
        uint128 volume;
        uint16 orderId;
    }

    function submitSolution(
        uint32 batchIndex,
        address[] memory owners,          // tradeData is submitted as arrays
        uint16[] memory orderIds,
        uint128[] memory volumes,
        uint128[] memory prices,          // list of prices for touched tokens only
        uint16[] memory tokenIdsForPrice  // price[i] is the price for the token with tokenID tokenIdsForPrice[i]
                                          // fee token id not required since always 0
    ) public {
        require(
            batchIndex == getCurrentBatchId() - 1,
            "Solutions are no longer accepted for this batch"
        );
        require(tokenIdsForPrice[0] == 0, "fee token price has to be specified");
        require(checkPriceOrdering(tokenIdsForPrice), "prices are not ordered by tokenId");
        undoPreviousSolution(batchIndex);
        updateCurrentPrices(prices, tokenIdsForPrice);
        delete previousSolution.trades;
        int[] memory tokenConservation = new int[](prices.length);
        for (uint i = 0; i < owners.length; i++) {
            Order memory order = orders[owners[i]][orderIds[i]];
            require(checkOrderValidity(order, batchIndex), "Order is invalid");
            (uint128 executedBuyAmount, uint128 executedSellAmount) = getTradedAmounts(volumes[i], order);
            tokenConservation.updateTokenConservation(
                order.buyToken,
                order.sellToken,
                tokenIdsForPrice,
                executedBuyAmount,
                executedSellAmount
            );
            require(order.remainingAmount >= executedSellAmount, "executedSellAmount bigger than specified in order");
            // Ensure executed price is not lower than the order price:
            //       executedSellAmount / executedBuyAmount <= order.priceDenominator / order.priceNumerator
            require(
                executedSellAmount.mul(order.priceNumerator) <= executedBuyAmount.mul(order.priceDenominator),
                "limit price not satisfied"
            );
            updateRemainingOrder(owners[i], orderIds[i], executedSellAmount);
            addBalanceAndBlockWithdrawForThisBatch(owners[i], tokenIdToAddressMap(order.buyToken), executedBuyAmount);
        }
        // doing all subtractions after all additions (in order to avoid negative values)
        for (uint i = 0; i < owners.length; i++) {
            (, uint128 executedSellAmount) = getTradedAmounts(
                volumes[i],
                orders[owners[i]][orderIds[i]]
            );
            subtractBalance(
                owners[i],
                tokenIdToAddressMap(orders[owners[i]][orderIds[i]].sellToken),
                executedSellAmount
            );
        }
        checkAndOverrideObjectiveValue(uint(tokenConservation[0]));
        grantRewardToSolutionSubmitter(uint(tokenConservation[0]) / 2);
        tokenConservation.checkTokenConservation();
        documentTrades(batchIndex, owners, orderIds, volumes, tokenIdsForPrice);
    }

    function getCurrentObjectiveValue() public view returns(uint) {
        if (previousSolution.batchId == getCurrentBatchId() - 1) {
            return previousSolution.objectiveValue;
        } else {
            return 0;
        }
    }

    function grantRewardToSolutionSubmitter(uint feeReward) internal {
        previousSolution.feeReward = feeReward;
        addBalanceAndBlockWithdrawForThisBatch(msg.sender, tokenIdToAddressMap(0), feeReward);
    }

    function updateCurrentPrices(
        uint128[] memory prices,          // list of prices for touched tokens only, frist price is fee token price
        uint16[] memory tokenIdsForPrice  // price[i] is the price for the token with tokenID tokenIdsForPrice[i]
    ) internal {
        for (uint i = 0; i < previousSolution.tokenIdsForPrice.length; i++) {
            currentPrices[previousSolution.tokenIdsForPrice[i]] = 0;
        }
        for (uint i = 0; i < tokenIdsForPrice.length; i++) {
            currentPrices[tokenIdsForPrice[i]] = prices[i];
        }
    }

    function getExecutedSellAmount(
        uint128 executedBuyAmount,
        uint128 buyTokenPrice,
        uint128 sellTokenPrice
    ) internal view returns (uint128) {
        // executedSellAmount = sellAmount * (1 - (1/feeDenominator))
        //                    = sellAmount - sellAmount/feeDenominator
        //                    = (sellAmount * feeDenominator) / feeDenominator - sellAmount/feeDenominator
        //                    = (sellAmount * feeDenominator - sellAmount) / feeDenominator
        //                    = (sellAmount * (feeDenominator - 1)) /feeDenominator
        //                    = (executedBuyAmount * buyTokenPrice / sellTokenPrice) * (feeDenominator - 1) / feeDenominator
        //                    in order to minimize rounding errors, the order is switched
        //                    = (executedBuyAmount * buyTokenPrice / feeDenominator) * (feeDenominator - 1) / sellTokenPrice
        uint256 sellAmount = (uint256(executedBuyAmount).mul(buyTokenPrice) / (feeDenominator - 1))
            .mul(feeDenominator) / sellTokenPrice;
        require(sellAmount < MAX_UINT128, "sellAmount too large");
        return uint128(sellAmount);
    }

    function updateRemainingOrder(
        address owner,
        uint orderId,
        uint128 executedAmount
    ) internal returns (uint) {
        orders[owner][orderId].remainingAmount = uint128(orders[owner][orderId].remainingAmount.sub(executedAmount));
    }

    function revertRemainingOrder(
        address owner,
        uint orderId,
        uint128 executedAmount
    ) internal returns (uint) {
        orders[owner][orderId].remainingAmount = uint128(orders[owner][orderId].remainingAmount.add(executedAmount));
    }

    function documentTrades(
        uint32 batchIndex,
        address[] memory owners,  // tradeData is submitted as arrays
        uint16[] memory orderIds,
        uint128[] memory volumes,
        uint16[] memory tokenIdsForPrice
    ) internal {
        previousSolution.batchId = batchIndex;
        for (uint i = 0; i < owners.length; i++) {
            previousSolution.trades.push(TradeData({
                owner: owners[i],
                orderId: orderIds[i],
                volume: volumes[i]
            }));
        }
        previousSolution.tokenIdsForPrice = tokenIdsForPrice;
        previousSolution.solutionSubmitter = msg.sender;
    }

    function undoPreviousSolution(uint32 batchIndex) internal {
        if (previousSolution.batchId == batchIndex) {
            for (uint i = 0; i < previousSolution.trades.length; i++) {
                address owner = previousSolution.trades[i].owner;
                uint orderId = previousSolution.trades[i].orderId;
                Order memory order = orders[owner][orderId];
                (, uint128 sellAmount) = getTradedAmounts(previousSolution.trades[i].volume, order);
                addBalance(owner, tokenIdToAddressMap(order.sellToken), sellAmount);
            }
            for (uint i = 0; i < previousSolution.trades.length; i++) {
                address owner = previousSolution.trades[i].owner;
                uint orderId = previousSolution.trades[i].orderId;
                Order memory order = orders[owner][orderId];
                (uint128 buyAmount, uint128 sellAmount) = getTradedAmounts(previousSolution.trades[i].volume, order);
                revertRemainingOrder(owner, orderId, sellAmount);
                subtractBalance(owner, tokenIdToAddressMap(order.buyToken), buyAmount);
            }
            // subtract granted fees:
            subtractBalance(
                previousSolution.solutionSubmitter,
                tokenIdToAddressMap(0),
                previousSolution.feeReward
            );
        }
    }

    function checkAndOverrideObjectiveValue(uint256 newObjectiveValue) private {
        require(
            newObjectiveValue > getCurrentObjectiveValue(),
            "Solution does not have a higher objective value than a previous solution"
        );
        previousSolution.objectiveValue = newObjectiveValue;
    }

    function getTradedAmounts(uint128 volume, Order memory order) private view returns (uint128, uint128) {
        // TODO: implement logic also for buyOrders
        uint128 executedBuyAmount = volume;
        require(currentPrices[order.sellToken] != 0, "prices are not allowed to be zero");
        uint128 executedSellAmount = getExecutedSellAmount(
            executedBuyAmount,
            currentPrices[order.buyToken],
            currentPrices[order.sellToken]
        );
        return (executedBuyAmount, executedSellAmount);
    }

    function checkOrderValidity(Order memory order, uint batchIndex) private pure returns (bool) {
        return order.validFrom <= batchIndex && order.validUntil >= batchIndex;
    }

    function checkPriceOrdering(uint16[] memory tokenIdsForPrice) private pure returns (bool) {
        for (uint i = 1; i < tokenIdsForPrice.length; i++) {
            if (tokenIdsForPrice[i] <= tokenIdsForPrice[i - 1]) {
                return false;
            }
        }
        return true;
    }

    function encodeAuctionElement(
        address user,
        uint256 sellTokenBalance,
        Order memory order
    ) private pure returns (bytes memory element) {
        element = abi.encodePacked(user);
        element = element.concat(abi.encodePacked(sellTokenBalance));
        element = element.concat(abi.encodePacked(order.buyToken));
        element = element.concat(abi.encodePacked(order.sellToken));
        element = element.concat(abi.encodePacked(order.validFrom));
        element = element.concat(abi.encodePacked(order.validUntil));
        element = element.concat(abi.encodePacked(order.isSellOrder));
        element = element.concat(abi.encodePacked(order.priceNumerator));
        element = element.concat(abi.encodePacked(order.priceDenominator));
        element = element.concat(abi.encodePacked(order.remainingAmount));
        return element;
    }
}
