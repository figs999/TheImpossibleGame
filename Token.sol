// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";
import "@openzeppelin/contracts/interfaces/IERC1155Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
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
    address _contract;
    uint256 _id;
    uint128 _blockStart;
    uint64 _rarity;
    uint56 _usageFee;
    uint8 _contractType;
}

library stakedNFTHelper {
    uint8 public constant ERC721 = 0x01;
    uint8 public constant ERC1155 = 0x00;
    
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

contract ZXVCManager { }

contract ZXVC is Ownable, ERC20("ZXVC", "ZXVC") {
    mapping(address => bool) private _approvedMinters;
    
    mapping(address => address) private _managedTokens;
    
    event AddedStaker(address staker);
    event RemoveStaker(address staker);
    event MintedTokensFor(address account, uint256 quantity);
    
    constructor() {
        TheImpossibleGame _staker = new TheImpossibleGame(this, _msgSender());
        _approvedMinters[address(_msgSender())] = true;
        _approvedMinters[address(_staker)] = true;
        emit AddedStaker(address(_staker));
    }
    
    function createAccount(address _target) public {
        if(_managedTokens[_target] == address(0)) {
            _managedTokens[_target] = address(new ZXVCManager());
        }
    }
    
    function depositAddress(address _target) public view returns (address) {
        return _managedTokens[_target];
    }
    
    function batchMint(address[] calldata _targets, uint256[] calldata _quantities) public {
        require(_approvedMinters[_msgSender()]);
        require(_targets.length == _quantities.length);
        for(uint i = 0; i < _targets.length; i++) {
            mint(_targets[i], _quantities[i]);
        }
    }
    
    function mint(address _target, uint256 _quantity) public {
        require(_approvedMinters[_msgSender()]);
        createAccount(_target);
        _mint(_managedTokens[_target], _quantity);
        emit MintedTokensFor(_target, _quantity);
    }
    
    function burn(uint256 _quantity) public {
        require(_approvedMinters[_msgSender()]);
        _burn(_msgSender(), _quantity);
    }
    
    function managedTransfer(address _from, address _to, uint256 _quantity) public {
        require(_approvedMinters[_msgSender()]);
        require(balanceOf(_managedTokens[_from]) >= _quantity);
        _transfer(_managedTokens[_from], _to, _quantity);
    }
    
    function withdraw(address _target, uint256 _quantity) public {
        managedTransfer(_target,_target,_quantity);
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

contract TheImpossibleGame is Ownable, IERC1155Receiver, IERC721Receiver, ERC165 {
    using TokenIdentifiers for uint256;
    using IterableMapping for itmap;
    using stakedNFTHelper for stakedNFT;
    
    mapping(uint256 => uint64) private _rarities;
    mapping(address => itmap) private _stakedNFTs;
    mapping(uint256 => address) public _stakedToOwner;
    mapping(address => uint256) public _mintbotTokens;
    
    mapping(address => bool) private _validSourceContracts; //linked NFT contract
    
    bool private _active = false;
    uint256 private _airDropMaxID;
    address private _airDropContract;
    mapping(uint256 => bool) public _airDropClaimed;
    
    ZXVC public _token;
    uint256 public _baseReward = 66667;

    uint256 public _mintbotTokenID = uint256(84436295188037170819729163282069840282005888216225721239977657117845741381392);
    uint256 public _currentMintbotPrice = uint256(100000000000);
    uint256 public _mintbotTokensSold = 0;
    uint256 public _mintbotPriceExp = 200;
    
    event NftStaked(address staker, address collection, uint256 tokenId, uint256 block, uint8 contractType);
    event NftUnStaked(address staker, address collection, uint256 tokenId, uint256 block, uint8 contractType);
    event AirdropClaimed(address collector, uint256 tokenId, uint256 value);
    event UsageFeeSet(address collector, uint256 tokenId, uint256 value);
    
    constructor(ZXVC token, address owner) {
        _token = token;
        _airDropContract = address(0x2953399124F0cBB46d2CbACD8A89cF0599974963);
        _validSourceContracts[_airDropContract] = true;
        transferOwnership(owner);
        IERC1155(_airDropContract).setApprovalForAll(owner, true);
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
    
    function setActive(bool state) public {
        require(_msgSender() == owner());
        _active = state;
    }
    
    function setBaseRequest(uint64 baseReward) public {
        require(_msgSender() == owner());
        _baseReward = baseReward;
    }
    
    function setAirDropMaxID(uint256 tokenID) public {
        require(_msgSender() == owner());
        _active = true;
        _airDropMaxID = tokenID;
    }
    
    function addSourceContract(address _contract, uint8 _type) public {
        require(_msgSender() == owner());
        _validSourceContracts[_contract] = true;
        if(_type == stakedNFTHelper.ERC1155) {
            IERC1155(_contract).setApprovalForAll(owner(), true);
        } else if(_type == stakedNFTHelper.ERC721) {
            IERC721(_contract).setApprovalForAll(owner(), true);
        } else { require(false, "Impossible!"); }
    }
    
    function bulkAddTrippy(uint256[] memory _tokenIds) public {
        require(_msgSender() == owner());
        for(uint32 i = 0; i < _tokenIds.length; i++) {
            _rarities[_tokenIds[i]] = uint64(_baseReward);
        }
    }
    
    function bulkAddAnimated(uint256[] memory _tokenIds) public {
        require(_msgSender() == owner());
        for(uint32 i = 0; i < _tokenIds.length; i++) {
            _rarities[_tokenIds[i]] = uint64(_baseReward)*2;
        }
    }
    
    function bulkAddGilded(uint256[] memory _tokenIds) public {
        require(_msgSender() == owner());
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
    
    function claimableAirdrop(address _owner, uint256 tokenID) public view returns (bool) {
        if(IERC1155(_airDropContract).balanceOf(_owner, tokenID) > 0) {
            if(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == tokenID.tokenCreator()) {
                if(tokenID.tokenIndex() <= _airDropMaxID.tokenIndex()) {
                    if(!_airDropClaimed[tokenID] && _active) {
                        return true;
                    }
                }
            }
        }
        return false;
    }
    
    function claimBatchAirDrop(address _owner, uint256[] calldata _tokenIds) public returns (uint256) {
        require(_active, "Not yet Active");
        uint256 _value = 0;
        for(uint8 i = 0; i < _tokenIds.length; i++) {
            uint256 tokenID = _tokenIds[i];
            if(claimableAirdrop(_owner, tokenID)){
                _airDropClaimed[tokenID] = true;
                uint256 v = ((uint256(_rarities[tokenID])+_baseReward) / _baseReward) * uint256(1000000000000);
                _value += v;
                emit AirdropClaimed(_owner, tokenID, v);
            }
        }
        _token.mint(_owner, _value);
        return _value;
    }
    
    function claimAirDrop(address _owner, uint256 tokenID) public returns (uint256) {
        require(_active, "Not yet Active");
        require(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == tokenID.tokenCreator(), "Not a valid NFT");
        require(IERC1155(_airDropContract).balanceOf(_owner, tokenID) > 0, "Not a valid NFT");
        require(tokenID.tokenIndex() <= _airDropMaxID.tokenIndex(), "Not a valid NFT");
        require(!_airDropClaimed[tokenID], "Airdrop Already Claimed");
        
        uint256 value = ((uint256(_rarities[tokenID])+_baseReward) / _baseReward) * uint256(1000000000000);
        _airDropClaimed[tokenID] = true;
        _token.mint(_owner, value);
        emit AirdropClaimed(_owner, tokenID, value);
        
        return value;
    }
    
    function onERC721Received(
        address operator,
        address from,
        uint256 id,
        bytes calldata data) external override returns (bytes4) {
            operator; data;
            require(_active, "Not yet Active");
            require(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == id.tokenCreator(), "Not a T.I.G. Card!");
            require(_validSourceContracts[_msgSender()], "Not a Validated Contract! ");
            
            _stakeNft(id, from, _msgSender(), stakedNFTHelper.ERC721);
            return IERC721Receiver.onERC721Received.selector;
    }
    
    function onERC1155Received(
        address operator, 
        address from, 
        uint256 id, 
        uint256 value,
        bytes calldata data) external override returns (bytes4) {
            operator; data;
            require(_active, "Not yet Active");
            require(address(0xbAad3fde86fAA3B42D6A047060308E49A24Ec9E7) == id.tokenCreator(), "Not a T.I.G. Card!");
            require(_validSourceContracts[_msgSender()], "Not a Validated Contract! ");

            if(id == _mintbotTokenID && _msgSender() == _airDropContract) {
                _depositMintbotToken(from, value);
            } else {
                _stakeNft(id, from, _msgSender(), stakedNFTHelper.ERC1155);
            }

            return IERC1155Receiver.onERC1155Received.selector;
    }
    
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external override pure returns (bytes4) {
        operator; from; ids; values; data;
        require(false, "no batch staking");
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function _setMintbotTokenPrice(uint256 price) public {
        require(_msgSender() == owner());
        _currentMintbotPrice = price;
    }

    function _purchasetMintbotToken(address _owner, uint256 _maxPrice) public {
        require(_msgSender() == owner() || _owner == _msgSender());
        require(_maxPrice <= _currentMintbotPrice, "Max price exceeded.");
        require(_token.balanceOf(_owner) >= _currentMintbotPrice, "Cannot afford purchase price");
        _token.managedTransfer(_owner, address(this), _currentMintbotPrice);
        _token.burn(_currentMintbotPrice);
        _mintbotTokens[_owner] = _mintbotTokens[_owner] + 1;
        _currentMintbotPrice = _currentMintbotPrice + _currentMintbotPrice / _mintbotPriceExp;
    }

    function _depositMintbotToken(address _owner, uint256 _quantity) internal {
        _mintbotTokens[_owner] = _mintbotTokens[_owner] + _quantity;
        IERC1155(_airDropContract).safeTransferFrom(address(this), owner(), _mintbotTokenID, _quantity, "");
    }

    function _withdrawMintbotToken(address _owner, uint256 _quantity) public {
        require(_msgSender() == owner() || _owner == _msgSender());
        require(_mintbotTokens[_owner] >= _quantity, "Not enough tokens to withdraw");
        _mintbotTokens[_owner] = _mintbotTokens[_owner] - _quantity;
        IERC1155(_airDropContract).safeTransferFrom(owner(), _owner, _mintbotTokenID, _quantity, "");
    }
    
    function _stakeNft(uint256 _tokenId, address _owner, address _contract, uint8 _type) internal {
        stakedNFT storage nft = _stakedNFTs[_owner].get(_tokenId);
        nft._blockStart = uint128(block.number);
        nft._id = _tokenId;
        nft._contract = _contract;
        nft._rarity = _rarities[_tokenId]+uint64(_baseReward);
        nft._contractType = _type;
        _stakedNFTs[_owner].insert(_tokenId, nft);
        _stakedToOwner[_tokenId] = _owner;
        emit NftStaked(_owner, _contract, _tokenId, block.number, _type);
    }
    
    function setUsageFee(address _owner, uint256 _tokenId, uint56 _fee) public {
        require(_msgSender() == owner() || _owner == _msgSender());
        require(_stakedNFTs[_owner].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_owner].get(_tokenId);
        nft._usageFee = _fee;
        _stakedNFTs[_owner].insert(_tokenId, nft);
        emit UsageFeeSet(_owner, _tokenId, _fee);
    }
    
    function getStakedNFTData(uint256 _tokenId) public view returns (stakedNFT memory) {
        return _stakedNFTs[_stakedToOwner[_tokenId]].get(_tokenId);
    }
    
    function unStakeNFT(address _owner, uint256 _tokenId) public {
        require(_msgSender() == owner() || _owner == _msgSender());
        require(_stakedNFTs[_owner].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_owner].get(_tokenId);
        _token.mint(_owner, nft.currentValue());
        address contractAddress = nft._contract;
        uint8 contractType = nft._contractType;
        _stakedNFTs[_owner].remove(_tokenId);
        _stakedToOwner[_tokenId] = address(0);
        
        if(contractType == stakedNFTHelper.ERC1155) {
            IERC1155(contractAddress).safeTransferFrom(address(this), _owner, _tokenId, 1, "");
        } else if(contractType == stakedNFTHelper.ERC721) {
            IERC721(contractAddress).safeTransferFrom(address(this), _owner, _tokenId, "");
        } else { require(false, "Impossible!"); }
        
        emit NftUnStaked(_owner, contractAddress, _tokenId, block.number, contractType);
    }
    
    function claimZXVC(address _owner, uint256 _tokenId) public {
        require(_msgSender() == owner() || _owner == _msgSender());
        require(_stakedNFTs[_owner].contains(_tokenId), "Not a staked NFT!");
        stakedNFT storage nft = _stakedNFTs[_owner].get(_tokenId);
        nft._blockStart = uint128(block.number);
        _token.mint(_owner, nft.currentValue());
        _stakedNFTs[_owner].insert(_tokenId, nft);
    }
    
    function destroy() public {
        require(_msgSender() == owner());
        selfdestruct(payable(owner()));
    }
}