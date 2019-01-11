pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";


contract BatchAuction is Ownable {

    uint16 public constant MAX_ACCOUNT_ID = 100;
    uint8 public constant MAX_TOKENS = 30;

    // struct PedersenHash {
    //     bool sign;
    //     bytes32 x;
    // }

    // uint stateIndex;
    bytes32[] public stateRoots;
    // mapping (uint => PedersenHash) public stateRoots;  // Pedersen hashes

    mapping (address => uint16) public publicKeyToAccountMap;
    mapping (uint16 => address) public accountToPublicKeyMap;

    uint8 public numTokens;
    mapping (address => uint8) public tokenAddresToIdMap;
    mapping (uint8 => address) public tokenIdToAddressMap;

    struct DepositState {
        bytes32 shaHash;
        bool applied;
    }
    
    uint public depositIndex;
    mapping (uint => DepositState) public depositHashes;

    event Deposit(uint16 accountId, uint8 tokenIndex, uint amount, uint slot);
    event IncrementDepositIndex(uint index);
    event StateTransistion(string transitionType, bytes32 from, bytes32 to);
    // event StateTransistion(string transitionType, PedersenHash from, PedersenHash to);

    modifier onlyRegistered() {
        require(publicKeyToAccountMap[msg.sender] != 0, "Must have registered account");
        _;
    }

    constructor () public {
        stateRoots.push(0);
        // stateRoots[stateIndex] = PedersenHash({sign: false, x: 0});
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
        
        // Increment depositIndex until it matches correct.
        uint nextDepositIndex = block.number / 20;
        while (depositIndex != nextDepositIndex) {
            depositIndex++;
            depositHashes[depositIndex] = DepositState({shaHash: 0, applied: false});
            emit IncrementDepositIndex(depositIndex);
        }

        uint16 accountId = publicKeyToAccountMap[msg.sender];
        bytes32 nextDepositHash = sha256(
            abi.encodePacked(depositHashes[depositIndex].shaHash, accountId, tokenIndex, amount)
        );

        depositHashes[depositIndex] = DepositState({shaHash: nextDepositHash, applied: false});

        emit Deposit(accountId, tokenIndex, amount, depositIndex);
    }

    function applyDeposits(
        uint slot,
        bytes32 _currDepositHash,
        bytes32 _currStateRoot,
        bytes32 _newStateRoot
        // PedersenHash memory _currStateRoot,
        // PedersenHash memory _newStateRoot
    )
        public onlyOwner()
    {   
        // Ensure exitance and inactivity of requested deposit slot
        require(slot != depositIndex, "Requested slot does not exist");
        require(slot < depositIndex, "Request deposit slot is still active");

        require(depositHashes[slot].applied == false, "Deposits have alread been applied");
        require(depositHashes[slot].shaHash == _currDepositHash, "Current deposit hash at slot doesn't agree");
        
        uint stateIndex = stateRoots.length - 1;
        require(stateRoots[stateIndex] == _currStateRoot, "Current stateRoot doesn't agree");
        // require(stateRoots[stateIndex].sign == _currStateRoot.sign, "Current stateRoot doesn't agree");
        // require(stateRoots[stateIndex].x == _currStateRoot.x, "Current stateRoot doesn't agree");

        // stateIndex++;
        // stateRoots[stateIndex] = _newStateRoot;
        stateRoots.push(_newStateRoot);        
        depositHashes[slot].applied == true;
        emit StateTransistion("applyDeposits", _currStateRoot, _newStateRoot);
    }
}