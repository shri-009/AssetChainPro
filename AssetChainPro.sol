// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * AssetChain Pro
 * - Admin-only minting (contract owner)
 * - On-chain metadata record (name, description, createdAt, tokenURI)
 * - Escrow marketplace (list, buy, cancel)
 * - Withdraw pattern for seller earnings
 */
contract AssetChainPro is ERC721, ERC721Holder, Ownable, ReentrancyGuard {
    using Strings for uint256;

    struct AssetMetadata {
        string name;
        string description;
        uint256 createdAt;
        string tokenURI_;
    }

    struct Listing {
        address seller;
        uint256 priceWei;
        bool active;
    }

    uint256 private _nextTokenId = 1;

    mapping(uint256 => AssetMetadata) private _assetMeta;
    mapping(uint256 => Listing) public listings;
    mapping(address => uint256) public pendingWithdrawals;

    event AssetMinted(
        uint256 indexed tokenId,
        address indexed to,
        string name,
        string description,
        string tokenURI,
        uint256 createdAt
    );
    event Listed(uint256 indexed tokenId, address indexed seller, uint256 priceWei);
    event Purchased(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 priceWei);
    event Cancelled(uint256 indexed tokenId, address indexed seller);

    error NotTokenOwner();
    error NotListed();
    error AlreadyListed();
    error InvalidPrice();
    error CannotBuyOwnAsset();
    error IncorrectPayment();
    error TransferFailed();

    constructor(address initialOwner) ERC721("AssetChain Pro", "ASSET") Ownable(initialOwner) {}

    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function mintAsset(
        address to,
        string calldata assetName,
        string calldata assetDescription,
        string calldata tokenUri
    ) external onlyOwner returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        _assetMeta[tokenId] = AssetMetadata({
            name: assetName,
            description: assetDescription,
            createdAt: block.timestamp,
            tokenURI_: tokenUri
        });

        emit AssetMinted(tokenId, to, assetName, assetDescription, tokenUri, block.timestamp);
    }

    function assetMetadata(uint256 tokenId) external view returns (AssetMetadata memory) {
        _requireOwned(tokenId);
        return _assetMeta[tokenId];
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _assetMeta[tokenId].tokenURI_;
    }

    function listForSale(uint256 tokenId, uint256 priceWei) external nonReentrant {
        if (priceWei == 0) revert InvalidPrice();
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (listings[tokenId].active) revert AlreadyListed();

        // Escrow transfer into this contract
        safeTransferFrom(msg.sender, address(this), tokenId);

        listings[tokenId] = Listing({seller: msg.sender, priceWei: priceWei, active: true});
        emit Listed(tokenId, msg.sender, priceWei);
    }

    function cancelListing(uint256 tokenId) external nonReentrant {
        Listing memory l = listings[tokenId];
        if (!l.active) revert NotListed();
        if (l.seller != msg.sender) revert NotTokenOwner();

        delete listings[tokenId];
        // Must use internal transfer: public safeTransferFrom checks msg.sender (seller) as operator,
        // but ownerOf is address(this) — would revert ERC721InsufficientApproval.
        _safeTransfer(address(this), msg.sender, tokenId, "");
        emit Cancelled(tokenId, msg.sender);
    }

    function buy(uint256 tokenId) external payable nonReentrant {
        Listing memory l = listings[tokenId];
        if (!l.active) revert NotListed();
        if (l.seller == msg.sender) revert CannotBuyOwnAsset();
        if (msg.value != l.priceWei) revert IncorrectPayment();

        delete listings[tokenId];

        // Credit seller, withdraw later
        pendingWithdrawals[l.seller] += msg.value;

        _safeTransfer(address(this), msg.sender, tokenId, "");
        emit Purchased(tokenId, l.seller, msg.sender, l.priceWei);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) return;
        pendingWithdrawals[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}

