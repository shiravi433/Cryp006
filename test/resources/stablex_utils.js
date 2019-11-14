const {
  waitForNSeconds,
  sendTxAndGetReturnValue,
} = require("../utilities")

/**
 * @typedef Deposit
 * @type {object}
 * @property {BN} amount The deposit amount
 * @property {number} token The deposited token
 * @property {number} user The user making the deposit
 */


/**
 * Makes deposit transactions from a list of Deposit Objects
 * @param {contract} - StablecoinConverter Smart Contract
 * @param {accounts} - an array of (unlocked) ethereum account addresses
 * @param {Deposit[]} - an array of Deposit Objects
 */
const makeDeposits = async function (contract, accounts, depositList) {
  for (const deposit of depositList) {
    const tokenAddress = await contract.tokenIdToAddressMap.call(deposit.token)
    await contract.deposit(tokenAddress, deposit.amount, { from: accounts[deposit.user] })
  }
}

/**
 * Makes placeOrder transactions from a list of Order Objects
 * @param {contract} - StablecoinConverter Smart Contract
 * @param {accounts} - an array of (unlocked) ethereum account addresses
 * @param {Order[]} - an array of Order Objects
 * @returns {BN[]}
 */
const placeOrders = async function (contract, accounts, orderList, auctionIndex) {
  const orderIds = []
  for (const order of orderList) {
    orderIds.push(
      await sendTxAndGetReturnValue(
        contract.placeOrder,
        order.buyToken,
        order.sellToken,
        auctionIndex,
        order.buyAmount,
        order.sellAmount,
        { from: accounts[order.user] }
      )
    )
  }
  return orderIds
}

/**
 * Closes current auction
 * @param {contract} - StablecoinConverter Smart Contract
 */
const closeAuction = async (contract) => {
  const time_remaining = (await contract.getSecondsRemainingInBatch()).toNumber()
  await waitForNSeconds(time_remaining + 1)
}

module.exports = {
  makeDeposits,
  placeOrders,
  closeAuction
}