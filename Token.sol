pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC1155Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenIdentifiers
 * support for authentication and metadata for token ids
 */
library TokenIdentifiers {
    uint8 constant ADDRESS_BITS = 160;
    uint8 constant INDEX_BITS = 56;
    uint8 constant SUPPLY_BITS = 40;
    
    uint256 constant SUPPLY_MASK =  0x000000000000000000000000000000000000000000000000000000FFFFFFFFFF;
    uint256 constant INDEX_MASK =   0x0000000000000000000000000000000000000000FFFFFFFFFFFFFF0000000000;
    uint256 constant INDEX_INCR =   0x0000000000000000000000000000000000000000000000000000010000000000;
    uint256 constant CREATOR_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000000000000000;

    function tokenVersion(uint256 _id) internal pure returns (uint256) {
        return _id & SUPPLY_MASK;
    }

    function tokenIndex(uint256 _id) internal pure returns (uint256) {
        return (_id >> SUPPLY_BITS) & INDEX_MASK;
    }

    function tokenCreator(uint256 _id) internal pure returns (address) {
        return address(uint160(_id >> (INDEX_BITS + SUPPLY_BITS)));
    }
    
    function nextIndex(uint256 _id) internal pure returns (uint256) {
        return _id + INDEX_INCR;
    }
    
    function minIndex(uint256 _id) internal pure returns (uint256) {
        return _id & CREATOR_MASK + 1;
    }
}

struct stakedNFT {
    IERC1155 _contract;
    uint256 _id;
    uint128 _blockStart;
    uint64 _rarity;
    uint64 _usageFee;
}

library stakedNFTHelper {
    function currentValue(stakedNFT storage _nft) internal view returns (uint256) {
        return (block.number - _nft._blockStart) * _nft._rarity;
    }
}

struct IndexValue { uint256 keyIndex; stakedNFT value; }
struct KeyFlag { uint256 key; bool deleted; }

struct itmap {
    mapping(uint256 => IndexValue) data;
    KeyFlag[] keys;
    uint size;
}

library IterableMapping {
    function insert(itmap storage self, uint256 key, stakedNFT storage value) internal returns (bool replaced) {
        uint keyIndex = self.data[key].keyIndex;
        self.data[key].value = value;
        if (keyIndex > 0)
            return true;
        else {
            keyIndex = self.keys.length;
            self.keys.push();
            self.data[key].keyIndex = keyIndex + 1;
            self.keys[keyIndex].key = key;
            self.size++;
            return false;
        }
    }

    function remove(itmap storage self, uint256 key) internal returns (bool success) {
        uint keyIndex = self.data[key].keyIndex;
        if (keyIndex == 0)
            return false;
        delete self.data[key];
        self.keys[keyIndex - 1].deleted = true;
        self.size --;
    }
    
    function get(itmap storage self, uint256 key) internal view returns (stakedNFT storage value) {
        return self.data[key].value;
    }

    function contains(itmap storage self, uint256 key) internal view returns (bool) {
        return self.data[key].keyIndex > 0;
    }

    function iterate_start(itmap storage self) internal view returns (uint256 keyIndex) {
        return iterate_next(self, type(uint).max);
    }

    function iterate_valid(itmap storage self, uint256 keyIndex) internal view returns (bool) {
        return keyIndex < self.keys.length;
    }

    function iterate_next(itmap storage self, uint256 keyIndex) internal view returns (uint256 r_keyIndex) {
        keyIndex++;
        while (keyIndex < self.keys.length && self.keys[keyIndex].deleted)
            keyIndex++;
        return keyIndex;
    }

    function iterate_get(itmap storage self, uint256 keyIndex) internal view returns (uint256 key, stakedNFT storage value) {
        key = self.keys[keyIndex].key;
        value = self.data[key].value;
    }
}

contract ZXVC is Ownable, ERC20("<TOKEN>", "ZXVC") {
    mapping(address => bool) private _approvedMinters;
    
    event AddedStaker(address staker);
    event RemoveStaker(address staker);
    
    constructor() {
        TIGStaking _staker = new TIGStaking(this);
        _staker.transferOwnership(_msgSender());
        _approvedMinters[address(_staker)] = true;
        emit AddedStaker(address(_staker));
    }
    
    function mint(address _target, uint256 _quantity) public {
        require(_approvedMinters[_msgSender()]);
        _mint(_target,_quantity);
    }
    
    function burn(address _target, uint256 _quantity) public {
        require(_approvedMinters[_msgSender()]);
        _burn(_target,_quantity);
    }
    
    function addMinter(address _staker) external {
        require(_msgSender() == owner());
        _approvedMinters[_staker] = true;
        emit AddedStaker(_staker);
    }
    
    function removeMinter(address _staker) external {
        require(_msgSender() == owner());
        _approvedMinters[_staker] = false;
        emit RemoveStaker(_staker);
    }
    
    function decimals() public view virtual override returns (uint8) {
      return 9;
    }
    
    function destroy() public {
        require(_msgSender() == owner());
        selfdestruct(payable(owner()));
    }
}

contract TIGStaking is Ownable, IERC1155Receiver, ERC165 {
    using TokenIdentifiers for uint256;
    using IterableMapping for itmap;
    using stakedNFTHelper for stakedNFT;
    
    mapping(uint256 => uint64) private _rarities;
    mapping(address => itmap) private _stakedNFTs;
    mapping(uint256 => address) private _stakedToOwner;
    
    mapping(address => bool) private _validSourceContracts; //linked NFT contract
    
    bool _active = false;
    uint256 _airDropMaxID;
    address _airDropContract;
    mapping(uint256 => bool) private _airDropClaimed;
    
    ZXVC _token;
    
    uint256 _baseReward = 66667;
    
    event NftStaked(address staker, address collection, uint256 tokenId, uint256 block);
    event AirdropClaimed(address collector, uint256 tokenId, uint256 value);
    
    constructor(ZXVC token) {
        _token = token;
        _airDropContract = address(0x2953399124F0cBB46d2CbACD8A89cF0599974963);
        _validSourceContracts[_airDropContract] = true;
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
    
    function setActive(bool state) public {
        require(_msgSender() == owner());
        _active = state;
    }
    
    function setAirDropMaxID(uint256 tokenID) public {
        require(_msgSender() == owner());
        _active = true;
        _airDropMaxID = tokenID;
    }
    
    function addSourceContract(address _contract) public {
        require(_msgSender() == owner());
        _validSourceContracts[_contract] = true;
    }
    
    function bulkAddTrippy(uint256[] memory _tokenIds) public {
        for(uint32 i = 0; i < _tokenIds.length; i++) {
            _rarities[_tokenIds[i]] = uint64(_baseReward);
        }
    }
    
    function bulkAddAnimated(uint256[] memory _tokenIds) public {
        for(uint32 i = 0; i < _tokenIds.length; i++) {
            _rarities[_tokenIds[i]] = uint64(_baseReward)*2;
        }
    }
    
    function bulkAddGilded(uint256[] memory _tokenIds) public {
        for(uint32 i = 0; i < _tokenIds.length; i++) {
            _rarities[_tokenIds[i]] = uint64(_baseReward)*4;
        }
    }
    
    function checkMinIndex(uint256 tokenID) public pure returns (uint256) {
        return tokenID.minIndex();
    }
    
    function checkNextIndex(uint256 tokenID) public pure returns (uint256) {
        return tokenID.nextIndex();
    }
    
    function claimableAirdrop(uint256 tokenID) public view returns (bool) {
        if(IERC1155(_airDropContract).balanceOf(_msgSender(), tokenID) > 0) {
            if(!_airDropClaimed[tokenID]) {
                return true;
            }
        }
        return false;
    }
    
    function claimBatchAirDrop(uint256[] calldata _tokenIds) public returns (uint256) {
        require(_active, "Not yet Active");
        uint256 _value = 0;
        for(uint8 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenID = _tokenIds[i];
            if(claimableAirdrop(tokenID)){
                _airDropClaimed[tokenID] = true;
                uint256 v = ((uint256(_rarities[tokenID])+_baseReward) / _baseReward) * uint256(1000000000000);
                _value += v;
                emit AirdropClaimed(_msgSender(), tokenID, v);
            }
        }
        _token.mint(_msgSender(), _value);
        return _value;
    }
    
    function claimAirDrop(uint256 tokenID) public returns (uint256) {
        require(_active, "Not yet Active");
        require(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == tokenID.tokenCreator(), "Not a valid NFT");
        require(IERC1155(_airDropContract).balanceOf(_msgSender(), tokenID) > 0, "Not a valid NFT");
        require(tokenID.tokenIndex() <= _airDropMaxID.tokenIndex(), "Not a valid NFT");
        require(!_airDropClaimed[tokenID], "Airdrop Already Claimed");
        
        uint256 value = ((uint256(_rarities[tokenID])+_baseReward) / _baseReward) * uint256(1000000000000);
        _airDropClaimed[tokenID] = true;
        _token.mint(_msgSender(), value);
        emit AirdropClaimed(_msgSender(), tokenID, value);
        
        return value;
    }
    
    function onERC1155Received(
        address operator, 
        address from, 
        uint256 id, 
        uint256 value,
        bytes calldata data) external override returns (bytes4) {
            require(_active, "Not yet Active");
            require(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == id.tokenCreator(), "Not a T.I.G. Card!");
            require(_validSourceContracts[_msgSender()], "Not a Validated Contract! ");
            
            _stakeNft(id, from, _msgSender());
            return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override pure returns (bytes4) {
        require(false, "no batch staking");
        return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function _stakeNft(uint256 _tokenId, address _owner, address _contract) internal {
        stakedNFT storage nft = _stakedNFTs[_owner].get(_tokenId);
        nft._blockStart = uint128(block.number);
        nft._id = _tokenId;
        nft._contract = IERC1155(_contract);
        nft._rarity = _rarities[_tokenId]+uint64(_baseReward);
        _stakedNFTs[_owner].insert(_tokenId, nft);
        _stakedToOwner[_tokenId] = _owner;
        emit NftStaked(_owner, _contract, _tokenId, block.number);
    }
    
    function setUsageFee(uint256 _tokenId, uint64 _fee) public {
        require(_stakedNFTs[_msgSender()].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_msgSender()].get(_tokenId);
        nft._usageFee = _fee;
        _stakedNFTs[_msgSender()].insert(_tokenId, nft);
    }
    
    function getStakedNFTData(uint256 _tokenId) public view returns (stakedNFT memory) {
        return _stakedNFTs[_stakedToOwner[_tokenId]].get(_tokenId);
    }
    
    function unStakeNFT(uint256 _tokenId) public {
        require(_stakedNFTs[_msgSender()].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_msgSender()].get(_tokenId);
        _token.mint(_msgSender(), nft.currentValue());
        nft._contract.safeTransferFrom(address(this), _msgSender(), nft._id, 1, "");
        _stakedNFTs[_msgSender()].remove(_tokenId);
        _stakedToOwner[_tokenId] = address(0);
    }
    
    function claimZXVC(uint256 _tokenId) public {
        require(_stakedNFTs[_msgSender()].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_msgSender()].get(_tokenId);
        _token.mint(_msgSender(), nft.currentValue());
        nft._blockStart = uint128(block.number);
        _stakedNFTs[_msgSender()].insert(_tokenId, nft);
    }
    
    function destroy() public {
        require(_msgSender() == owner());
        selfdestruct(payable(owner()));
    }
}