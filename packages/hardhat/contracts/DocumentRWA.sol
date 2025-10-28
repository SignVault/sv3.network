// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DocumentRWA
 * @dev Manages documents as RWA (Real World Asset) NFTs for sv3.network
 * Handles document creation, signature management, and NFT functionality
 */
contract DocumentRWA is ERC721, ERC721URIStorage, Ownable {
    struct DocumentVersion {
        uint256 versionNumber;        // Version number (1, 2, 3, ...)
        string title;                 // Document title at this version
        string contentHash;           // IPFS content hash at this version
        string metadataHash;          // IPFS metadata hash at this version
        address modifiedBy;           // Address that created this version
        uint256 timestamp;            // Version creation timestamp
        string changeDescription;     // Description of changes made
    }

    struct TemplateField {
        string fieldName;             // Name of the field (e.g., "Title", "Date", "Amount")
        string fieldType;             // Type of field (e.g., "text", "number", "date", "address")
        bool isRequired;              // Whether the field is mandatory
        string defaultValue;          // Default value for the field
    }

    struct DocumentTemplate {
        uint256 id;                   // Unique template ID
        string name;                  // Template name (e.g., "Invoice", "Contract")
        string description;           // Template description
        string category;              // Template category (e.g., "Legal", "Financial")
        address creator;              // Template creator address
        TemplateField[] fields;       // Array of template fields
        string contentStructure;      // IPFS hash of template structure/layout
        uint256 createdAt;            // Creation timestamp
        uint256 lastModified;         // Last modification timestamp
        bool isActive;                // Template status
        bool isPublic;                // Whether template is publicly available
    }

    struct Document {
        uint256 id;                    // Unique document ID (NFT token ID)
        address owner;                // Document owner wallet address
        uint256 organizationId;       // Parent organization ID
        string title;                 // Document title
        string contentHash;           // IPFS content hash (SHA256)
        string metadataHash;          // IPFS metadata hash
        address[] signers;            // List of authorized signers
        mapping(address => bool) signatures; // <-- Critical: Stores signers per document
        // mapping(address => bool) signatures; // Signature tracking
        uint256 createdAt;            // Creation timestamp
        uint256 lastModified;         // Last modification timestamp
        uint256 currentVersion;       // Current version number
        bool isActive;                // Document status
    }
    mapping(uint256 => mapping(address => bool)) public docApprovers;
    mapping(uint256 => Document) public documents;
    mapping(address => uint256[]) public userDocuments;
    mapping(uint256 => DocumentVersion[]) public documentVersions; // docId => version history
    mapping(uint256 => DocumentTemplate) public templates; // templateId => template
    mapping(address => uint256[]) public userTemplates; // user => template IDs
    mapping(uint256 => uint256) public documentTemplate; // docId => templateId (tracks which template was used)

    uint256 public documentCount;
    uint256 public signatureCount;
    uint256 public templateCount;

    event DocumentCreated(uint256 indexed docId, address indexed owner, uint256 indexed orgId, string title);
    event DocumentUpdated(uint256 indexed docId, string newTitle);
    event DocumentSigned(uint256 indexed docId, address indexed signer);
    event SignatureVerified(uint256 indexed docId, address indexed signer, bool isValid);
    event DocumentDeleted(uint256 indexed docId);
    event VersionCreated(uint256 indexed docId, uint256 indexed versionNumber, address indexed modifiedBy, string changeDescription);
    event TemplateCreated(uint256 indexed templateId, address indexed creator, string name);
    event TemplateUpdated(uint256 indexed templateId, string name);
    event TemplateDeleted(uint256 indexed templateId);
    event DocumentCreatedFromTemplate(uint256 indexed docId, uint256 indexed templateId, address indexed owner);

    error DocumentNotFound();
    error Unauthorized();
    error InvalidIPFSHash();
    error AlreadySigned();
    error NotAuthorizedSigner();
    error OrganizationNotFound();
    error InvalidDocumentTitle();
    error VersionNotFound();
    error InvalidPagination();
    error TemplateNotFound();
    error InvalidTemplateName();
    error InvalidTemplateField();
    error TemplateNotActive();

    modifier onlyDocumentOwner(uint256 docId) {
        require(documents[docId].owner == msg.sender, "Only document owner");
        _;
    }

    modifier documentExists(uint256 docId) {
        require(documents[docId].id != 0, "Document not found");
        _;
    }

    modifier activeDocument(uint256 docId) {
        require(documents[docId].isActive, "Document is not active");
        _;
    }

    modifier templateExists(uint256 templateId) {
        require(templates[templateId].id != 0, "Template not found");
        _;
    }

    modifier onlyTemplateCreator(uint256 templateId) {
        require(templates[templateId].creator == msg.sender, "Only template creator");
        _;
    }

    constructor(address initialOwner)
        ERC721("DocumentRWA", "DRWA") // Example: Name and Symbol for ERC721
        Ownable(initialOwner)        // Pass initialOwner to Ownable
    {}

    /**
     * @dev Create a new document as NFT
     * @param organizationId Parent organization ID
     * @param title Document title
     * @param contentHash IPFS content hash
     * @param metadataHash IPFS metadata hash
     */
    function createDocument(
        uint256 organizationId,
        string memory title,
        string memory contentHash,
        string memory metadataHash
    ) external {
        require(bytes(title).length >= 3 && bytes(title).length <= 100, "Title must be 3-100 characters");
        _validateIPFSHash(contentHash);
        _validateIPFSHash(metadataHash);

        documentCount++;
        uint256 docId = documentCount;

        Document storage doc = documents[docId];
        doc.id = docId;
        doc.owner = msg.sender;
        doc.organizationId = organizationId;
        doc.title = title;
        doc.contentHash = contentHash;
        doc.metadataHash = metadataHash;
        doc.createdAt = block.timestamp;
        doc.lastModified = block.timestamp;
        doc.currentVersion = 1;
        doc.isActive = true;

        // Create initial version
        DocumentVersion memory initialVersion = DocumentVersion({
            versionNumber: 1,
            title: title,
            contentHash: contentHash,
            metadataHash: metadataHash,
            modifiedBy: msg.sender,
            timestamp: block.timestamp,
            changeDescription: "Initial version"
        });
        documentVersions[docId].push(initialVersion);

        // Mint NFT to document owner
        _mint(msg.sender, docId);
        _setTokenURI(docId, metadataHash);

        // Add to user's documents
        userDocuments[msg.sender].push(docId);

        emit DocumentCreated(docId, msg.sender, organizationId, title);
    }

    /**
     * @dev Update document details
     * @param docId Document ID
     * @param newTitle New document title
     */
    function updateDocument(uint256 docId, string memory newTitle) external
        onlyDocumentOwner(docId)
        documentExists(docId)
        activeDocument(docId)
    {
        require(bytes(newTitle).length >= 3 && bytes(newTitle).length <= 100, "Title must be 3-100 characters");

        documents[docId].title = newTitle;
        documents[docId].lastModified = block.timestamp;

        emit DocumentUpdated(docId, newTitle);
    }

    /**
     * @dev Add authorized signer to document
     * @param docId Document ID
     * @param signer Signer wallet address
     */
    function addSigner(uint256 docId, address signer) external
        onlyDocumentOwner(docId)
        documentExists(docId)
        activeDocument(docId)
    {
        require(signer != address(0), "Invalid address");
        require(!documents[docId].signatures[signer], "Already a signer");

        documents[docId].signers.push(signer);
    }

    /**
     * @dev Remove signer from document
     * @param docId Document ID
     * @param signer Signer wallet address
     */
    function removeSigner(uint256 docId, address signer) external
        onlyDocumentOwner(docId)
        documentExists(docId)
        activeDocument(docId)
    {
        require(signer != documents[docId].owner, "Cannot remove owner as signer");
        require(documents[docId].signatures[signer], "Not a signer");

        // Remove from signers array
        Document storage doc = documents[docId];
        for (uint i = 0; i < doc.signers.length; i++) {
            if (doc.signers[i] == signer) {
                doc.signers[i] = doc.signers[doc.signers.length - 1];
                doc.signers.pop();
                break;
            }
        }

        // Remove signature if exists
        if (doc.signatures[signer]) {
            doc.signatures[signer] = false;
            signatureCount--;
        }
    }

    /**
     * @dev Sign a document
     * @param docId Document ID
     * @param signatureData ECDSA signature data
     */
    function signDocument(uint256 docId, bytes memory signatureData) external
        documentExists(docId)
        activeDocument(docId)
    {
        require(_isAuthorizedSigner(docId, msg.sender), "Not authorized signer");
        require(!documents[docId].signatures[msg.sender], "Already signed");

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(docId, msg.sender, block.timestamp));
        address recoveredSigner = _recoverSigner(messageHash, signatureData);

        require(recoveredSigner == msg.sender, "Invalid signature");

        documents[docId].signatures[msg.sender] = true;
        documents[docId].lastModified = block.timestamp;
        signatureCount++;

        emit DocumentSigned(docId, msg.sender);
        emit SignatureVerified(docId, msg.sender, true);
    }

    /**
     * @dev Delete document (owner only)
     * @param docId Document ID
     */
    function deleteDocument(uint256 docId) external onlyDocumentOwner(docId) documentExists(docId) {
        Document storage doc = documents[docId];
        doc.isActive = false;
        doc.lastModified = block.timestamp;

        // Burn NFT
        _burn(docId);

        // Remove from user's documents
        _removeFromUserDocuments(msg.sender, docId);

        emit DocumentDeleted(docId);
    }

    /**
     * @dev Get document details
     */
    function getDocument(uint256 docId)
    external
    view
    documentExists(docId)
    returns (
        uint256 id,
        string memory uri,
        address owner
    )
        {
            Document storage doc = documents[docId];
            return (doc.id, doc.contentHash, doc.owner);
        }

    /**
     * @dev Check if document is signed by address
     */
    function isSigned(uint256 docId, address signer) external view documentExists(docId) returns (bool) {
        return documents[docId].signatures[signer];
    }

    /**
     * @dev Get document signers
     */
    function getDocumentSigners(uint256 docId) external view documentExists(docId) returns (address[] memory) {
        return documents[docId].signers;
    }

    /**
     * @dev Get signature count for document
     */
    function getSignatureCount(uint256 docId) external view documentExists(docId) returns (uint256) {
        uint256 count = 0;
        Document storage doc = documents[docId];
        for (uint i = 0; i < doc.signers.length; i++) {
            if (doc.signatures[doc.signers[i]]) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Get user's documents
     */
    function getUserDocuments(address user) external view returns (uint256[] memory) {
        return userDocuments[user];
    }

    /**
     * @dev Check if user is authorized signer
     */
    function isAuthorizedSigner(uint256 docId, address signer) external view documentExists(docId) returns (bool) {
        return _isAuthorizedSigner(docId, signer);
    }

    /**
     * @dev Internal function to validate IPFS hash
     */
    function _validateIPFSHash(string memory hash) internal pure {
        bytes memory hashBytes = bytes(hash);
        require(hashBytes.length > 0, "IPFS hash cannot be empty");
        require(hashBytes.length <= 128, "IPFS hash too long");
        // Additional validation can be added for CID format
    }

    /**
     * @dev Internal function to check if user is authorized signer
     */
    function _isAuthorizedSigner(uint256 docId, address signer) internal view returns (bool) {
        Document storage doc = documents[docId];

        // Owner can always sign
        if (signer == doc.owner) return true;

        // Check if in authorized signers list
        for (uint i = 0; i < doc.signers.length; i++) {
            if (doc.signers[i] == signer) return true;
        }

        return false;
    }

    /**
     * @dev Internal function to recover signer from signature
     */
    function _recoverSigner(bytes32 messageHash, bytes memory signatureData) internal pure returns (address) {
        require(signatureData.length == 65, "Invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signatureData, 32))
            s := mload(add(signatureData, 64))
            v := byte(0, mload(add(signatureData, 96)))
        }

        if (v < 27) {
            v += 27;
        }

        require(v == 27 || v == 28, "Invalid signature version");

        return ecrecover(messageHash, v, r, s);
    }

    /**
     * @dev Internal function to remove document from user's list
     */
    function _removeFromUserDocuments(address user, uint256 docId) internal {
        uint256[] storage userDocs = userDocuments[user];
        for (uint i = 0; i < userDocs.length; i++) {
            if (userDocs[i] == docId) {
                userDocs[i] = userDocs[userDocs.length - 1];
                userDocs.pop();
                break;
            }
        }
    }

    /**
     * @dev Transfer document ownership
     */
    function transferDocumentOwnership(uint256 docId, address newOwner) external
        onlyDocumentOwner(docId)
        documentExists(docId)
        activeDocument(docId)
    {
        require(newOwner != address(0), "Invalid address");
        require(newOwner != documents[docId].owner, "Already owner");

        address oldOwner = documents[docId].owner;
        documents[docId].owner = newOwner;
        documents[docId].lastModified = block.timestamp;

        // Transfer NFT
        _transfer(oldOwner, newOwner, docId);

        // Update user document lists
        _removeFromUserDocuments(oldOwner, docId);
        userDocuments[newOwner].push(docId);
    }

    /**
     * @dev Get active documents count
     */
    function getActiveDocumentCount() external view returns (uint256) {
        return documentCount;
    }

    /**
     * @dev Get total signatures count
     */
    function getTotalSignatureCount() external view returns (uint256) {
        return signatureCount;
    }

    // Override required by Solidity
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ============ Version History Functions ============

    /**
     * @dev Get version history for a document with pagination
     * @param docId Document ID
     * @param offset Starting index for pagination (0-based)
     * @param limit Maximum number of versions to return
     * @return versions Array of document versions
     * @return totalCount Total number of versions available
     */
    function getVersionHistory(
        uint256 docId,
        uint256 offset,
        uint256 limit
    )
        external
        view
        documentExists(docId)
        returns (DocumentVersion[] memory versions, uint256 totalCount)
    {
        DocumentVersion[] storage allVersions = documentVersions[docId];
        totalCount = allVersions.length;

        if (offset >= totalCount) {
            revert InvalidPagination();
        }

        // Calculate actual number of items to return
        uint256 end = offset + limit;
        if (end > totalCount) {
            end = totalCount;
        }
        uint256 resultCount = end - offset;

        // Create result array
        versions = new DocumentVersion[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            versions[i] = allVersions[offset + i];
        }

        return (versions, totalCount);
    }

    /**
     * @dev Get all version history for a document (no pagination)
     * @param docId Document ID
     * @return versions Array of all document versions
     */
    function getAllVersionHistory(uint256 docId)
        external
        view
        documentExists(docId)
        returns (DocumentVersion[] memory versions)
    {
        return documentVersions[docId];
    }

    /**
     * @dev Get total number of versions for a document
     * @param docId Document ID
     * @return count Total version count
     */
    function getVersionCount(uint256 docId)
        external
        view
        documentExists(docId)
        returns (uint256 count)
    {
        return documentVersions[docId].length;
    }

    /**
     * @dev Get a specific version of a document
     * @param docId Document ID
     * @param versionNumber Version number to retrieve (1-based)
     * @return version The requested document version
     */
    function getSpecificVersion(uint256 docId, uint256 versionNumber)
        external
        view
        documentExists(docId)
        returns (DocumentVersion memory version)
    {
        require(versionNumber > 0, "Version number must be greater than 0");
        require(versionNumber <= documentVersions[docId].length, "Version does not exist");

        // Version numbers are 1-based, array indices are 0-based
        return documentVersions[docId][versionNumber - 1];
    }

    /**
     * @dev Get the latest version of a document
     * @param docId Document ID
     * @return version The latest document version
     */
    function getLatestVersion(uint256 docId)
        external
        view
        documentExists(docId)
        returns (DocumentVersion memory version)
    {
        DocumentVersion[] storage versions = documentVersions[docId];
        require(versions.length > 0, "No versions exist");
        return versions[versions.length - 1];
    }

    /**
     * @dev Get version history in reverse order (latest first) with pagination
     * @param docId Document ID
     * @param offset Starting index from the end (0 = latest)
     * @param limit Maximum number of versions to return
     * @return versions Array of document versions in reverse order
     * @return totalCount Total number of versions available
     */
    function getVersionHistoryReverse(
        uint256 docId,
        uint256 offset,
        uint256 limit
    )
        external
        view
        documentExists(docId)
        returns (DocumentVersion[] memory versions, uint256 totalCount)
    {
        DocumentVersion[] storage allVersions = documentVersions[docId];
        totalCount = allVersions.length;

        if (offset >= totalCount) {
            revert InvalidPagination();
        }

        // Calculate actual number of items to return
        uint256 resultCount = limit;
        if (offset + limit > totalCount) {
            resultCount = totalCount - offset;
        }

        // Create result array in reverse order
        versions = new DocumentVersion[](resultCount);
        for (uint256 i = 0; i < resultCount; i++) {
            uint256 reverseIndex = totalCount - 1 - offset - i;
            versions[i] = allVersions[reverseIndex];
        }

        return (versions, totalCount);
    }

    /**
     * @dev Create a new version when document is updated
     * @param docId Document ID
     * @param newTitle New document title
     * @param newContentHash New IPFS content hash
     * @param newMetadataHash New IPFS metadata hash
     * @param changeDescription Description of changes made
     */
    function createNewVersion(
        uint256 docId,
        string memory newTitle,
        string memory newContentHash,
        string memory newMetadataHash,
        string memory changeDescription
    )
        external
        onlyDocumentOwner(docId)
        documentExists(docId)
        activeDocument(docId)
    {
        require(bytes(newTitle).length >= 3 && bytes(newTitle).length <= 100, "Title must be 3-100 characters");
        _validateIPFSHash(newContentHash);
        _validateIPFSHash(newMetadataHash);

        Document storage doc = documents[docId];
        doc.currentVersion++;
        doc.title = newTitle;
        doc.contentHash = newContentHash;
        doc.metadataHash = newMetadataHash;
        doc.lastModified = block.timestamp;

        // Create new version entry
        DocumentVersion memory newVersion = DocumentVersion({
            versionNumber: doc.currentVersion,
            title: newTitle,
            contentHash: newContentHash,
            metadataHash: newMetadataHash,
            modifiedBy: msg.sender,
            timestamp: block.timestamp,
            changeDescription: changeDescription
        });
        documentVersions[docId].push(newVersion);

        emit VersionCreated(docId, doc.currentVersion, msg.sender, changeDescription);
        emit DocumentUpdated(docId, newTitle);
    }

    // ============ Template Management Functions ============

    /**
     * @dev Create a new document template
     * @param name Template name
     * @param description Template description
     * @param category Template category
     * @param fieldNames Array of field names
     * @param fieldTypes Array of field types
     * @param isRequired Array indicating if fields are required
     * @param defaultValues Array of default values for fields
     * @param contentStructure IPFS hash of template structure
     * @param isPublic Whether template is publicly available
     */
    function createTemplate(
        string memory name,
        string memory description,
        string memory category,
        string[] memory fieldNames,
        string[] memory fieldTypes,
        bool[] memory isRequired,
        string[] memory defaultValues,
        string memory contentStructure,
        bool isPublic
    ) external {
        require(bytes(name).length >= 3 && bytes(name).length <= 100, "Name must be 3-100 characters");
        require(fieldNames.length == fieldTypes.length, "Field arrays length mismatch");
        require(fieldNames.length == isRequired.length, "Field arrays length mismatch");
        require(fieldNames.length == defaultValues.length, "Field arrays length mismatch");
        require(fieldNames.length > 0, "Template must have at least one field");
        _validateIPFSHash(contentStructure);

        templateCount++;
        uint256 templateId = templateCount;

        DocumentTemplate storage template = templates[templateId];
        template.id = templateId;
        template.name = name;
        template.description = description;
        template.category = category;
        template.creator = msg.sender;
        template.contentStructure = contentStructure;
        template.createdAt = block.timestamp;
        template.lastModified = block.timestamp;
        template.isActive = true;
        template.isPublic = isPublic;

        // Add template fields
        for (uint256 i = 0; i < fieldNames.length; i++) {
            require(bytes(fieldNames[i]).length > 0, "Field name cannot be empty");
            require(bytes(fieldTypes[i]).length > 0, "Field type cannot be empty");
            
            template.fields.push(TemplateField({
                fieldName: fieldNames[i],
                fieldType: fieldTypes[i],
                isRequired: isRequired[i],
                defaultValue: defaultValues[i]
            }));
        }

        // Add to user's templates
        userTemplates[msg.sender].push(templateId);

        emit TemplateCreated(templateId, msg.sender, name);
    }

    /**
     * @dev Update an existing template
     * @param templateId Template ID
     * @param name New template name
     * @param description New template description
     * @param category New template category
     * @param contentStructure New IPFS hash of template structure
     */
    function updateTemplate(
        uint256 templateId,
        string memory name,
        string memory description,
        string memory category,
        string memory contentStructure
    )
        external
        templateExists(templateId)
        onlyTemplateCreator(templateId)
    {
        require(bytes(name).length >= 3 && bytes(name).length <= 100, "Name must be 3-100 characters");
        _validateIPFSHash(contentStructure);

        DocumentTemplate storage template = templates[templateId];
        require(template.isActive, "Template is not active");

        template.name = name;
        template.description = description;
        template.category = category;
        template.contentStructure = contentStructure;
        template.lastModified = block.timestamp;

        emit TemplateUpdated(templateId, name);
    }

    /**
     * @dev Delete a template (soft delete)
     * @param templateId Template ID
     */
    function deleteTemplate(uint256 templateId)
        external
        templateExists(templateId)
        onlyTemplateCreator(templateId)
    {
        templates[templateId].isActive = false;
        templates[templateId].lastModified = block.timestamp;

        emit TemplateDeleted(templateId);
    }

    /**
     * @dev Create a document from a template
     * @param templateId Template ID to use
     * @param organizationId Parent organization ID
     * @param title Document title
     * @param contentHash IPFS content hash
     * @param metadataHash IPFS metadata hash
     */
    function createDocumentFromTemplate(
        uint256 templateId,
        uint256 organizationId,
        string memory title,
        string memory contentHash,
        string memory metadataHash
    )
        external
        templateExists(templateId)
    {
        DocumentTemplate storage template = templates[templateId];
        require(template.isActive, "Template is not active");
        require(
            template.isPublic || template.creator == msg.sender,
            "Template is private"
        );

        require(bytes(title).length >= 3 && bytes(title).length <= 100, "Title must be 3-100 characters");
        _validateIPFSHash(contentHash);
        _validateIPFSHash(metadataHash);

        documentCount++;
        uint256 docId = documentCount;

        Document storage doc = documents[docId];
        doc.id = docId;
        doc.owner = msg.sender;
        doc.organizationId = organizationId;
        doc.title = title;
        doc.contentHash = contentHash;
        doc.metadataHash = metadataHash;
        doc.createdAt = block.timestamp;
        doc.lastModified = block.timestamp;
        doc.currentVersion = 1;
        doc.isActive = true;

        // Track which template was used
        documentTemplate[docId] = templateId;

        // Create initial version
        DocumentVersion memory initialVersion = DocumentVersion({
            versionNumber: 1,
            title: title,
            contentHash: contentHash,
            metadataHash: metadataHash,
            modifiedBy: msg.sender,
            timestamp: block.timestamp,
            changeDescription: string(abi.encodePacked("Created from template: ", template.name))
        });
        documentVersions[docId].push(initialVersion);

        // Mint NFT to document owner
        _mint(msg.sender, docId);
        _setTokenURI(docId, metadataHash);

        // Add to user's documents
        userDocuments[msg.sender].push(docId);

        emit DocumentCreated(docId, msg.sender, organizationId, title);
        emit DocumentCreatedFromTemplate(docId, templateId, msg.sender);
    }

    /**
     * @dev Get template details
     * @param templateId Template ID
     * @return id Template ID
     * @return name Template name
     * @return description Template description
     * @return category Template category
     * @return creator Template creator address
     * @return contentStructure IPFS hash of template structure
     * @return createdAt Creation timestamp
     * @return lastModified Last modification timestamp
     * @return isActive Template status
     * @return isPublic Public availability status
     */
    function getTemplate(uint256 templateId)
        external
        view
        templateExists(templateId)
        returns (
            uint256 id,
            string memory name,
            string memory description,
            string memory category,
            address creator,
            string memory contentStructure,
            uint256 createdAt,
            uint256 lastModified,
            bool isActive,
            bool isPublic
        )
    {
        DocumentTemplate storage template = templates[templateId];
        return (
            template.id,
            template.name,
            template.description,
            template.category,
            template.creator,
            template.contentStructure,
            template.createdAt,
            template.lastModified,
            template.isActive,
            template.isPublic
        );
    }

    /**
     * @dev Get template fields
     * @param templateId Template ID
     * @return fields Array of template fields
     */
    function getTemplateFields(uint256 templateId)
        external
        view
        templateExists(templateId)
        returns (TemplateField[] memory fields)
    {
        return templates[templateId].fields;
    }

    /**
     * @dev Get user's templates
     * @param user User address
     * @return Array of template IDs
     */
    function getUserTemplates(address user) external view returns (uint256[] memory) {
        return userTemplates[user];
    }

    /**
     * @dev Get template used for a document
     * @param docId Document ID
     * @return templateId Template ID (0 if not created from template)
     */
    function getDocumentTemplate(uint256 docId)
        external
        view
        documentExists(docId)
        returns (uint256 templateId)
    {
        return documentTemplate[docId];
    }

    /**
     * @dev Get total template count
     * @return Total number of templates
     */
    function getTotalTemplateCount() external view returns (uint256) {
        return templateCount;
    }

    /**
     * @dev Toggle template public/private status
     * @param templateId Template ID
     */
    function toggleTemplateVisibility(uint256 templateId)
        external
        templateExists(templateId)
        onlyTemplateCreator(templateId)
    {
        DocumentTemplate storage template = templates[templateId];
        require(template.isActive, "Template is not active");
        
        template.isPublic = !template.isPublic;
        template.lastModified = block.timestamp;

        emit TemplateUpdated(templateId, template.name);
    }
}