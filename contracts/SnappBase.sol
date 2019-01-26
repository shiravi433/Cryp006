pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "./Merkle.sol";


contract SnappBase is Ownable {
    using Merkle for bytes32;

    uint16 public constant MAX_ACCOUNT_ID = 100;     // TODO - make larger or use uint8
    uint8 public constant MAX_TOKENS = 30;
    uint16 public constant MAX_DEPOSIT_BATCH = 100;  // TODO - make larger or use uint8
    uint16 public constant MAX_WITHDRAW_BATCH = 100;
    
    bytes32[] public stateRoots;  // Pedersen Hash

    enum TransitionType {
        Deposit,
        Withdraw,
        Auction
    }

    // Account Mapping
    mapping (address => uint16) public publicKeyToAccountMap;
    mapping (uint16 => address) public accountToPublicKeyMap;

    // Token Mapping
    uint8 public numTokens;
    mapping (address => uint8) public tokenAddresToIdMap;
    mapping (uint8 => address) public tokenIdToAddressMap;

    struct DepositState {
        uint16 size;                   // Number of deposits in this batch
        bytes32 shaHash;               // Rolling shaHash of all deposits
        uint creationBlock;            // Timestamp of batch creation
        uint appliedAccountStateIndex; // accountState index when batch applied (for rollback)
    }

    uint public depositIndex;
    mapping (uint => DepositState) public deposits;

    struct PendingWithdrawState {
        uint16 size; //number of withdraws that have been made in this batch
        bytes32 shaHash; //rolling shaHash of all pending withdraws
        uint creationBlock; //timestamp of when batch was created
        uint appliedAccountStateIndex; //AccountState when this batch was applied (for rollback)
    }

    struct ClaimableWithdrawState {
        bytes32 merkleRoot; // Merkle root of claimable withdraws in this block
        bool[100] claimedBitmap; // Bitmap signalling which withdraws have been claimed
        uint appliedAccountStateIndex; // AccountState when this state was created (for rollback)
    }

    PendingWithdrawState[] public pendingWithdraws;
    ClaimableWithdrawState[] public claimableWithdraws;

    event WithdrawRequest(uint16 accountId, uint8 tokenId, uint amount, uint slot, uint16 slotIndex);
    event Deposit(uint16 accountId, uint8 tokenId, uint amount, uint slot, uint16 slotIndex);
    event StateTransition(TransitionType transitionType, uint stateIndex, bytes32 stateHash, uint slot);
    event SnappInitialization(bytes32 stateHash, uint8 maxTokens, uint16 maxAccounts);

    constructor () public {
        // The initial state should be Pederson hash of an empty balance tree
        bytes32 stateInit = bytes32(0);  // TODO
        stateRoots.push(stateInit);
        deposits[depositIndex] = DepositState({
            size: 0,
            shaHash: bytes32(0),
            creationBlock: block.number,
            appliedAccountStateIndex: 0
        });
        pendingWithdraws.push(
            PendingWithdrawState({
                size: 0,
                shaHash: bytes32(0),
                creationBlock: block.number,
                appliedAccountStateIndex: 0
            })
        );

        emit SnappInitialization(stateInit, MAX_TOKENS, MAX_ACCOUNT_ID);
    }

    // Public View 
    function stateIndex() public view returns (uint) {
        return stateRoots.length - 1;
    }

    function hasDepositBeenApplied(uint index) public view returns (bool) {
        return deposits[index].appliedAccountStateIndex != 0;
    }

    function isDepositSlotEmpty(uint index) public view returns (bool) {
        return deposits[index].shaHash == bytes32(0);
    }

    function getCurrentStateRoot() public view returns (bytes32) {
        return stateRoots[stateIndex()];
    }

    // Modifiers
    modifier onlyRegistered() {
        require(publicKeyToAccountMap[msg.sender] != 0, "Must have registered account");
        _;
    }

    function openAccount(uint16 accountId) public {
        require(accountId != 0, "Account index must be positive!");
        require(accountId <= MAX_ACCOUNT_ID, "Account index exceeds max");

        // Ensure bijectivity of this maps (i.e. address can't occupy > 1 slots)
        require(publicKeyToAccountMap[msg.sender] == 0, "Address occupies account slot");
        require(accountToPublicKeyMap[accountId] == address(0), "Account slot occupied");

        publicKeyToAccountMap[msg.sender] = accountId;
        accountToPublicKeyMap[accountId] = msg.sender;
    }

    function addToken(address _tokenAddress) public onlyOwner() {
        require(tokenAddresToIdMap[_tokenAddress] == 0, "Token already registered!");
        require(numTokens + 1 <= MAX_TOKENS, "Token id exceeds max tokens");

        tokenAddresToIdMap[_tokenAddress] = numTokens + 1;
        tokenIdToAddressMap[numTokens + 1] = _tokenAddress;

        numTokens++;
    }

    function deposit(uint8 tokenIndex, uint amount) public onlyRegistered() {
        require(amount != 0, "Must deposit positive amount");

        address tokenAddress = tokenIdToAddressMap[tokenIndex];
        require(tokenAddress != address(0), "Requested token is not registered");
        require(
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount), 
            "Unsuccessful transfer"
        );

        if (deposits[depositIndex].size == MAX_DEPOSIT_BATCH || block.number > deposits[depositIndex].creationBlock + 20) {
            depositIndex++;
            deposits[depositIndex] = DepositState({
                size: 0,
                shaHash: bytes32(0),
                creationBlock: block.number,
                appliedAccountStateIndex: 0   // Default 0 implies not applied.
            });
        }

        // Update Deposit Hash based on request
        uint16 accountId = publicKeyToAccountMap[msg.sender];
        bytes32 nextDepositHash = sha256(
            abi.encodePacked(deposits[depositIndex].shaHash, accountId, tokenIndex, amount)
        );
        deposits[depositIndex].shaHash = nextDepositHash;
        deposits[depositIndex].size++;

        emit Deposit(accountId, tokenIndex, amount, depositIndex, deposits[depositIndex].size);
    }

    function applyDeposits(
        uint slot,
        bytes32 _currStateRoot,
        bytes32 _newStateRoot
    )
        public onlyOwner()
    {   
        require(slot <= depositIndex, "Requested deposit slot does not exist");

        require(slot == 0 || deposits[slot-1].appliedAccountStateIndex != 0, "Must apply deposit slots in order!");
        require(deposits[slot].appliedAccountStateIndex == 0, "Deposits already processed");
        require(block.number > deposits[slot].creationBlock + 20, "Requested deposit slot is still active");
        require(stateRoots[stateIndex()] == _currStateRoot, "Incorrect State Root");

        // Note that the only slot that can ever be empty is the first (at index zero) 
        // This occurs when no deposits are made within the first 20 blocks of the contract's deployment
        // This code allows for the processing of the empty block and since it will only happen once
        // No, additional verificaiton is necessary.  

        stateRoots.push(_newStateRoot);        
        deposits[slot].appliedAccountStateIndex = stateIndex();

        emit StateTransition(TransitionType.Deposit, stateIndex(), _newStateRoot, slot);
    }

    function requestWithdrawal(uint8 tokenId, uint amount) public onlyRegistered() {
        require(amount != 0, "Must request positive amount");

        address tokenAddress = tokenIdToAddressMap[tokenId];
        require(tokenAddress != address(0), "Requested token is not registered");
        require(
            ERC20(tokenAddress).balanceOf(address(this)) >= amount,
            "Requested amount exceeds contract's balance"
        );

        // Determine or construct correct current withdraw state.
        // This is governed by MAX_WITHDRAW_BATCH and creationBlock
        uint withdrawIndex = pendingWithdraws.length - 1;
        PendingWithdrawState memory currWithdrawState = pendingWithdraws[withdrawIndex];
        if (currWithdrawState.size == MAX_WITHDRAW_BATCH || block.number > currWithdrawState.creationBlock + 20) {
            currWithdrawState = PendingWithdrawState({
                size: 0,
                shaHash: bytes32(0),
                creationBlock: block.number,
                appliedAccountStateIndex: 0  // Default 0 implies not applied.
            });
            pendingWithdraws.push(currWithdrawState);
            withdrawIndex++;
        }

        // Update Withdraw Hash based on request
        uint16 accountId = publicKeyToAccountMap[msg.sender];
        bytes32 nextWithdrawHash = sha256(
            abi.encodePacked(currWithdrawState.shaHash, accountId, tokenId, amount)
        );
        currWithdrawState.shaHash = nextWithdrawHash;
        currWithdrawState.size++;

        pendingWithdraws[withdrawIndex] = currWithdrawState;

        emit WithdrawRequest(accountId, tokenId, amount, withdrawIndex, currWithdrawState.size);
    }

    function applyWithdrawals(
        uint slot,
        bool[100] memory includedBitMap,
        bytes32 _merkleRoot,
        bytes32 _currStateRoot,
        bytes32 _newStateRoot
    )
        public onlyOwner()
    {
        require(slot < pendingWithdraws.length - 1, "Withdraw slot must exist and be inactive");
        require(pendingWithdraws[slot].appliedAccountStateIndex == 0, "Withdraws already processed");
        require(pendingWithdraws[slot].shaHash != bytes32(0), "Withdraws slot is empty");
        require(stateRoots[stateIndex()] == _currStateRoot, "Incorrect State Root");

        // Update account states
        stateRoots.push(_newStateRoot);
        pendingWithdraws[slot].appliedAccountStateIndex = stateIndex();
        
        claimableWithdraws.push(
            ClaimableWithdrawState({
                merkleRoot: _merkleRoot,
                claimedBitmap: includedBitMap,
                appliedAccountStateIndex: stateIndex()
            })
        );

        emit StateTransition(TransitionType.Withdraw, stateIndex(), _newStateRoot, slot);
    }

}
