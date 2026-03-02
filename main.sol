// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title DoppelBanger
/// @notice Twin-entry attestation ledger for mirrored claims and strike resolution; dual-record binding with bounty hooks.

contract DoppelBanger {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event TwinRegistered(bytes32 indexed pairId, bytes32 leftHash, bytes32 rightHash, address indexed binder, uint256 atBlock);
    event MirrorStruck(bytes32 indexed pairId, uint8 side, address indexed striker, bytes32 reasonHash, uint256 atBlock);
    event PairResolved(bytes32 indexed pairId, uint8 outcome, address indexed resolver, uint256 atBlock);
    event BountyPosted(bytes32 indexed pairId, uint256 amountWei, address indexed poster, uint256 atBlock);
    event BountyClaimed(bytes32 indexed pairId, address indexed claimant, uint256 amountWei, uint256 atBlock);
    event StripeAdded(bytes32 indexed stripeId, bytes32 anchorHash, address indexed adder, uint256 atBlock);
    event StripeLinked(bytes32 indexed stripeId, bytes32 indexed pairId, uint256 atBlock);
    event KeeperRotated(address indexed previousKeeper, address indexed newKeeper, uint256 atBlock);
    event ArbiterSet(address indexed previousArbiter, address indexed newArbiter, uint256 atBlock);
    event NamespaceFrozen(bytes32 indexed namespaceId, bool frozen, uint256 atBlock);
    event BatchTwinsRegistered(uint256 count, address indexed by, uint256 atBlock);
    event PairUnbound(bytes32 indexed pairId, address indexed by, uint256 atBlock);
    event MaxPairsPerBinderUpdated(uint256 previous, uint256 next, uint256 atBlock);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event TreasuryTopped(uint256 amountWei, uint256 atBlock);
    event RefundIssued(address indexed to, uint256 amountWei, bytes32 indexed reasonHash, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error DB_ZeroPair();
    error DB_ZeroHash();
    error DB_ZeroAddress();
    error DB_NotKeeper();
    error DB_NotArbiter();
    error DB_PairNotFound();
    error DB_AlreadyResolved();
    error DB_NotResolved();
    error DB_NotBinder();
    error DB_ReentrantCall();
    error DB_MaxPairsReached();
    error DB_MaxPairsPerBinderReached();
    error DB_NamespaceFrozen();
    error DB_InvalidSide();
    error DB_InvalidBatchLength();
    error DB_DuplicatePair();
    error DB_StripeNotFound();
    error DB_InvalidOutcome();
    error DB_TransferFailed();
    error DB_ZeroAmount();
    error DB_InsufficientBounty();
    error DB_AlreadyStruck();
    error DB_InvalidFeeBps();
    error DB_StripeAlreadyLinked();
    error DB_NotStripeOwner();
    error DB_MaxStripesReached();
    error DB_InvalidStripeIndex();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant DB_MAX_PAIRS = 750_000;
    uint256 public constant DB_MAX_PAIRS_PER_BINDER = 12_000;
    uint256 public constant DB_MAX_BATCH = 72;
    uint256 public constant DB_MAX_STRIPES = 256;
    uint256 public constant DB_FEE_BPS_CAP = 600;
    uint256 public constant DB_SIDES = 2;
    bytes32 public constant DB_NAMESPACE = keccak256("DoppelBanger.DB_NAMESPACE");
    bytes32 public constant DB_VERSION = keccak256("doppel-banger.v1");
    uint256 public constant DB_OUTCOME_NONE = 0;
    uint256 public constant DB_OUTCOME_LEFT = 1;
    uint256 public constant DB_OUTCOME_RIGHT = 2;
    uint256 public constant DB_OUTCOME_TIE = 3;

    // -------------------------------------------------------------------------
    // IMMUTABLES
    // -------------------------------------------------------------------------

    address public immutable keeper;
    address public immutable arbiter;
    address public immutable treasury;
    address public immutable stripeAnchorA;
    address public immutable stripeAnchorB;
    address public immutable feeCollector;
    uint256 public immutable deployBlock;

    // -------------------------------------------------------------------------
    // STATE
    // -------------------------------------------------------------------------

    struct TwinPair {
        bytes32 leftHash;
        bytes32 rightHash;
        address binder;
        uint256 registeredAtBlock;
        uint8 resolutionOutcome;
        bool resolved;
        uint256 strikeCountLeft;
        uint256 strikeCountRight;
        uint256 bountyWei;
        bool bountyClaimed;
    }

    struct Stripe {
        bytes32 anchorHash;
        address owner;
        uint256 createdAtBlock;
        bytes32 linkedPairId;
        bool linked;
    }

    mapping(bytes32 => TwinPair) private _pairs;
    bytes32[] private _pairIds;
    uint256 public pairCount;

    mapping(address => bytes32[]) private _pairIdsByBinder;
    mapping(address => uint256) private _pairCountByBinder;

    mapping(bytes32 => bool) private _namespaceFrozen;
    uint256 public maxPairsPerBinder = 2_000;
    uint256 public feeBps = 45;
    uint256 private _reentrancyLock;

    mapping(bytes32 => Stripe) private _stripes;
    bytes32[] private _stripeIds;
    uint256 public stripeCount;

    mapping(bytes32 => mapping(uint8 => mapping(address => bool))) private _struckBy;
    mapping(bytes32 => address[]) private _strikersLeft;
    mapping(bytes32 => address[]) private _strikersRight;

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        keeper = address(0x0000000000000000000000000000000000000000);
        arbiter = address(0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb);
        treasury = address(0x52908400098527886E0F7030069857D2E4169EE7);
        stripeAnchorA = address(0x8617E340B3D01FA5F11F306F4090FD50E238070D);
        stripeAnchorB = address(0x27b1fdb04752bbc536007a920d24acb045561c26);
        feeCollector = address(0xde0B295669a9FD93d5F28D9Ec85E40f4cb697BAe);
        deployBlock = block.number;
        if (arbiter == address(0)) revert DB_ZeroAddress();
        if (treasury == address(0)) revert DB_ZeroAddress();
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyKeeper() {
        if (msg.sender != keeper && keeper != address(0)) revert DB_NotKeeper();
        _;
    }

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert DB_NotArbiter();
        _;
    }

    modifier whenNotFrozen(bytes32 namespaceId) {
        if (_namespaceFrozen[namespaceId]) revert DB_NamespaceFrozen();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert DB_ReentrantCall();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    // -------------------------------------------------------------------------
    // CORE: REGISTER TWIN PAIR
    // -------------------------------------------------------------------------

    function registerTwin(bytes32 pairId, bytes32 leftHash, bytes32 rightHash)
        external
        nonReentrant
        whenNotFrozen(DB_NAMESPACE)
        returns (bool)
    {
        if (pairId == bytes32(0)) revert DB_ZeroPair();
        if (leftHash == bytes32(0) || rightHash == bytes32(0)) revert DB_ZeroHash();
        if (_pairs[pairId].registeredAtBlock != 0) revert DB_DuplicatePair();
        if (pairCount >= DB_MAX_PAIRS) revert DB_MaxPairsReached();
        if (_pairCountByBinder[msg.sender] >= maxPairsPerBinder) revert DB_MaxPairsPerBinderReached();

        _pairs[pairId] = TwinPair({
            leftHash: leftHash,
            rightHash: rightHash,
            binder: msg.sender,
            registeredAtBlock: block.number,
            resolutionOutcome: 0,
            resolved: false,
            strikeCountLeft: 0,
            strikeCountRight: 0,
            bountyWei: 0,
            bountyClaimed: false
        });
        _pairIds.push(pairId);
        pairCount++;
        _pairIdsByBinder[msg.sender].push(pairId);
        _pairCountByBinder[msg.sender]++;

        emit TwinRegistered(pairId, leftHash, rightHash, msg.sender, block.number);
        return true;
    }

    function strikeMirror(bytes32 pairId, uint8 side, bytes32 reasonHash) external nonReentrant {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        if (p.resolved) revert DB_AlreadyResolved();
        if (side >= DB_SIDES) revert DB_InvalidSide();
        if (_struckBy[pairId][side][msg.sender]) revert DB_AlreadyStruck();

        _struckBy[pairId][side][msg.sender] = true;
        if (side == 0) {
            p.strikeCountLeft++;
            _strikersLeft[pairId].push(msg.sender);
        } else {
            p.strikeCountRight++;
            _strikersRight[pairId].push(msg.sender);
        }

        emit MirrorStruck(pairId, side, msg.sender, reasonHash, block.number);
    }

    function resolvePair(bytes32 pairId, uint8 outcome) external onlyArbiter nonReentrant {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        if (p.resolved) revert DB_AlreadyResolved();
        if (outcome > DB_OUTCOME_TIE) revert DB_InvalidOutcome();

        p.resolved = true;
        p.resolutionOutcome = outcome;

        emit PairResolved(pairId, outcome, msg.sender, block.number);
    }

    function postBounty(bytes32 pairId) external payable nonReentrant {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        if (p.resolved) revert DB_AlreadyResolved();
        if (msg.value == 0) revert DB_ZeroAmount();

        p.bountyWei += msg.value;

        emit BountyPosted(pairId, msg.value, msg.sender, block.number);
    }

    function claimBounty(bytes32 pairId) external nonReentrant {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        if (!p.resolved) revert DB_NotResolved();
        if (p.bountyClaimed) revert DB_InsufficientBounty();
        if (p.bountyWei == 0) revert DB_ZeroAmount();
        if (msg.sender != arbiter && msg.sender != p.binder) revert DB_NotBinder();

        p.bountyClaimed = true;
        uint256 amount = p.bountyWei;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert DB_TransferFailed();

        emit BountyClaimed(pairId, msg.sender, amount, block.number);
    }

    // -------------------------------------------------------------------------
    // STRIPES
    // -------------------------------------------------------------------------

    function addStripe(bytes32 stripeId, bytes32 anchorHash) external nonReentrant whenNotFrozen(DB_NAMESPACE) {
        if (stripeId == bytes32(0)) revert DB_ZeroHash();
        if (anchorHash == bytes32(0)) revert DB_ZeroHash();
        if (_stripes[stripeId].createdAtBlock != 0) revert DB_DuplicatePair();
        if (stripeCount >= DB_MAX_STRIPES) revert DB_MaxStripesReached();

        _stripes[stripeId] = Stripe({
            anchorHash: anchorHash,
            owner: msg.sender,
            createdAtBlock: block.number,
            linkedPairId: bytes32(0),
            linked: false
        });
        _stripeIds.push(stripeId);
        stripeCount++;

        emit StripeAdded(stripeId, anchorHash, msg.sender, block.number);
    }

    function linkStripeToPair(bytes32 stripeId, bytes32 pairId) external nonReentrant {
        Stripe storage s = _stripes[stripeId];
        if (s.createdAtBlock == 0) revert DB_StripeNotFound();
        if (msg.sender != s.owner) revert DB_NotStripeOwner();
        if (s.linked) revert DB_StripeAlreadyLinked();
        if (_pairs[pairId].registeredAtBlock == 0) revert DB_PairNotFound();

        s.linkedPairId = pairId;
        s.linked = true;

        emit StripeLinked(stripeId, pairId, block.number);
    }

    // -------------------------------------------------------------------------
    // BATCH REGISTER
    // -------------------------------------------------------------------------

    function batchRegisterTwins(
        bytes32[] calldata pairIds,
        bytes32[] calldata leftHashes,
        bytes32[] calldata rightHashes
    ) external nonReentrant whenNotFrozen(DB_NAMESPACE) returns (uint256 registered) {
        if (pairIds.length != leftHashes.length || leftHashes.length != rightHashes.length) revert DB_InvalidBatchLength();
        if (pairIds.length > DB_MAX_BATCH) revert DB_InvalidBatchLength();
        if (pairCount + pairIds.length > DB_MAX_PAIRS) revert DB_MaxPairsReached();
        if (_pairCountByBinder[msg.sender] + pairIds.length > maxPairsPerBinder) revert DB_MaxPairsPerBinderReached();

        for (uint256 i = 0; i < pairIds.length; i++) {
            if (pairIds[i] == bytes32(0) || leftHashes[i] == bytes32(0) || rightHashes[i] == bytes32(0)) continue;
            if (_pairs[pairIds[i]].registeredAtBlock != 0) continue;

            _pairs[pairIds[i]] = TwinPair({
                leftHash: leftHashes[i],
                rightHash: rightHashes[i],
                binder: msg.sender,
                registeredAtBlock: block.number,
                resolutionOutcome: 0,
                resolved: false,
                strikeCountLeft: 0,
                strikeCountRight: 0,
                bountyWei: 0,
                bountyClaimed: false
            });
            _pairIds.push(pairIds[i]);
            pairCount++;
            _pairIdsByBinder[msg.sender].push(pairIds[i]);
            _pairCountByBinder[msg.sender]++;
            registered++;
            emit TwinRegistered(pairIds[i], leftHashes[i], rightHashes[i], msg.sender, block.number);
        }
        if (registered > 0) emit BatchTwinsRegistered(registered, msg.sender, block.number);
        return registered;
    }

    // -------------------------------------------------------------------------
    // KEEPER / ARBITER (keeper optional when zero)
    // -------------------------------------------------------------------------

    function setNamespaceFrozen(bytes32 namespaceId, bool frozen) external onlyKeeper {
        _namespaceFrozen[namespaceId] = frozen;
        emit NamespaceFrozen(namespaceId, frozen, block.number);
    }

    function setMaxPairsPerBinder(uint256 newMax) external onlyKeeper {
        uint256 prev = maxPairsPerBinder;
        maxPairsPerBinder = newMax > DB_MAX_PAIRS_PER_BINDER ? DB_MAX_PAIRS_PER_BINDER : newMax;
        emit MaxPairsPerBinderUpdated(prev, maxPairsPerBinder, block.number);
    }

    function setFeeBps(uint256 newBps) external onlyKeeper {
        if (newBps > DB_FEE_BPS_CAP) revert DB_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newBps;
        emit FeeBpsUpdated(prev, feeBps, block.number);
    }

    function unboundPair(bytes32 pairId) external onlyArbiter nonReentrant {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        if (p.resolved) revert DB_AlreadyResolved();

        address binder = p.binder;
        _pairCountByBinder[binder]--;
        delete _pairs[pairId];
        pairCount--;

        emit PairUnbound(pairId, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // TREASURY
    // -------------------------------------------------------------------------

    receive() external payable {
        emit TreasuryTopped(msg.value, block.number);
    }

    function withdrawToTreasury(uint256 amountWei) external onlyKeeper nonReentrant {
        if (treasury == address(0)) revert DB_ZeroAddress();
        (bool ok,) = treasury.call{value: amountWei}("");
        if (!ok) revert DB_TransferFailed();
    }

    function issueRefund(address to, uint256 amountWei, bytes32 reasonHash) external onlyArbiter nonReentrant {
        if (to == address(0)) revert DB_ZeroAddress();
        if (amountWei == 0) revert DB_ZeroAmount();
        (bool ok,) = to.call{value: amountWei}("");
        if (!ok) revert DB_TransferFailed();
        emit RefundIssued(to, amountWei, reasonHash, block.number);
    }

    // -------------------------------------------------------------------------
    // VIEW: PAIR BY ID
    // -------------------------------------------------------------------------

    function getPair(bytes32 pairId)
        external
        view
        returns (
            bytes32 leftHash,
            bytes32 rightHash,
            address binder,
            uint256 registeredAtBlock,
            uint8 resolutionOutcome,
            bool resolved,
            uint256 strikeCountLeft,
            uint256 strikeCountRight,
            uint256 bountyWei,
            bool bountyClaimed
        )
    {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        return (
            p.leftHash,
            p.rightHash,
            p.binder,
            p.registeredAtBlock,
            p.resolutionOutcome,
            p.resolved,
            p.strikeCountLeft,
            p.strikeCountRight,
            p.bountyWei,
            p.bountyClaimed
        );
    }

    function getLeftHash(bytes32 pairId) external view returns (bytes32) {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        return p.leftHash;
    }

    function getRightHash(bytes32 pairId) external view returns (bytes32) {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        return p.rightHash;
    }

    function getBinder(bytes32 pairId) external view returns (address) {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        return p.binder;
    }

    function isResolved(bytes32 pairId) external view returns (bool) {
        return _pairs[pairId].resolved;
    }

    function getResolutionOutcome(bytes32 pairId) external view returns (uint8) {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        return p.resolutionOutcome;
    }

    function pairExists(bytes32 pairId) external view returns (bool) {
        return _pairs[pairId].registeredAtBlock != 0;
    }

    function getBountyWei(bytes32 pairId) external view returns (uint256) {
        return _pairs[pairId].bountyWei;
    }

    function hasStruck(bytes32 pairId, uint8 side, address account) external view returns (bool) {
        if (side >= DB_SIDES) revert DB_InvalidSide();
        return _struckBy[pairId][side][account];
    }

    // -------------------------------------------------------------------------
    // VIEW: LISTS
    // -------------------------------------------------------------------------

    function getPairIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _pairIds.length) revert DB_PairNotFound();
        return _pairIds[index];
    }

    function getPairIdsByBinder(address binder) external view returns (bytes32[] memory) {
        return _pairIdsByBinder[binder];
    }

    function getPairCountByBinder(address binder) external view returns (uint256) {
        return _pairCountByBinder[binder];
    }

    function getAllPairIds() external view returns (bytes32[] memory) {
        return _pairIds;
    }

    function getStrikersLeft(bytes32 pairId) external view returns (address[] memory) {
        return _strikersLeft[pairId];
    }

    function getStrikersRight(bytes32 pairId) external view returns (address[] memory) {
        return _strikersRight[pairId];
    }

    // -------------------------------------------------------------------------
    // VIEW: STRIPES
    // -------------------------------------------------------------------------

    function getStripe(bytes32 stripeId)
        external
        view
        returns (bytes32 anchorHash, address owner, uint256 createdAtBlock, bytes32 linkedPairId, bool linked)
    {
        Stripe storage s = _stripes[stripeId];
        if (s.createdAtBlock == 0) revert DB_StripeNotFound();
        return (s.anchorHash, s.owner, s.createdAtBlock, s.linkedPairId, s.linked);
    }

    function getStripeIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _stripeIds.length) revert DB_StripeNotFound();
        return _stripeIds[index];
    }

    function stripeExists(bytes32 stripeId) external view returns (bool) {
        return _stripes[stripeId].createdAtBlock != 0;
    }

    // -------------------------------------------------------------------------
    // VIEW: CONFIG
    // -------------------------------------------------------------------------

    function isNamespaceFrozen(bytes32 namespaceId) external view returns (bool) {
        return _namespaceFrozen[namespaceId];
    }

    function totalPairCount() external view returns (uint256) {
        return _pairIds.length;
    }

    function totalStripeCount() external view returns (uint256) {
        return _stripeIds.length;
    }

    // -------------------------------------------------------------------------
    // UTILITY: HASH HELPERS
    // -------------------------------------------------------------------------

    function hashTwinPayload(bytes calldata leftPayload, bytes calldata rightPayload) external pure returns (bytes32 leftHash, bytes32 rightHash) {
        leftHash = keccak256(leftPayload);
        rightHash = keccak256(rightPayload);
    }

    function hashTwinStrings(string calldata leftStr, string calldata rightStr) external pure returns (bytes32 leftHash, bytes32 rightHash) {
        leftHash = keccak256(bytes(leftStr));
        rightHash = keccak256(bytes(rightStr));
    }

    function derivePairId(bytes32 leftHash, bytes32 rightHash, address binder, uint256 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(leftHash, rightHash, binder, salt));
    }

    // -------------------------------------------------------------------------
    // BULK VIEW: PAIRS IN RANGE
    // -------------------------------------------------------------------------

    function getPairsInRange(uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (
            bytes32[] memory pairIds,
            bytes32[] memory leftHashes,
            bytes32[] memory rightHashes,
            address[] memory binders,
            bool[] memory resolvedFlags
        )
    {
        if (fromIndex > toIndex || toIndex >= _pairIds.length) revert DB_InvalidStripeIndex();
        uint256 len = toIndex - fromIndex + 1;
        pairIds = new bytes32[](len);
        leftHashes = new bytes32[](len);
        rightHashes = new bytes32[](len);
        binders = new address[](len);
        resolvedFlags = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _pairIds[fromIndex + i];
            TwinPair storage p = _pairs[id];
            pairIds[i] = id;
            leftHashes[i] = p.leftHash;
            rightHashes[i] = p.rightHash;
            binders[i] = p.binder;
            resolvedFlags[i] = p.resolved;
        }
    }

    // -------------------------------------------------------------------------
    // BULK VIEW: STRIPES IN RANGE
    // -------------------------------------------------------------------------

    function getStripesInRange(uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (
            bytes32[] memory stripeIds,
            bytes32[] memory anchorHashes,
            address[] memory owners,
            bool[] memory linkedFlags
        )
    {
        if (fromIndex > toIndex || toIndex >= _stripeIds.length) revert DB_InvalidStripeIndex();
        uint256 len = toIndex - fromIndex + 1;
        stripeIds = new bytes32[](len);
        anchorHashes = new bytes32[](len);
        owners = new address[](len);
        linkedFlags = new bool[](len);

        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _stripeIds[fromIndex + i];
            Stripe storage s = _stripes[id];
            stripeIds[i] = id;
            anchorHashes[i] = s.anchorHash;
            owners[i] = s.owner;
            linkedFlags[i] = s.linked;
        }
    }

    // -------------------------------------------------------------------------
    // STATS
    // -------------------------------------------------------------------------

    function getGlobalStats()
        external
        view
        returns (
            uint256 totalPairs,
            uint256 totalStripes,
            uint256 deployBlockNum,
            uint256 currentFeeBps,
            uint256 currentMaxPairsPerBinder
        )
    {
        return (
            _pairIds.length,
            _stripeIds.length,
            deployBlock,
            feeBps,
            maxPairsPerBinder
        );
    }

    function getBinderStats(address binder)
        external
        view
        returns (uint256 pairCountForBinder, uint256 maxAllowed)
    {
        return (_pairCountByBinder[binder], maxPairsPerBinder);
    }

    // -------------------------------------------------------------------------
    // PAIR RESOLUTION HELPERS
    // -------------------------------------------------------------------------

    function resolutionOutcomeNone() external pure returns (uint8) {
        return uint8(DB_OUTCOME_NONE);
    }

    function resolutionOutcomeLeft() external pure returns (uint8) {
        return uint8(DB_OUTCOME_LEFT);
    }

    function resolutionOutcomeRight() external pure returns (uint8) {
        return uint8(DB_OUTCOME_RIGHT);
    }

    function resolutionOutcomeTie() external pure returns (uint8) {
        return uint8(DB_OUTCOME_TIE);
    }

    // -------------------------------------------------------------------------
    // NAMESPACE / VERSION
    // -------------------------------------------------------------------------

    function namespaceId() external pure returns (bytes32) {
        return DB_NAMESPACE;
    }

    function versionHash() external pure returns (bytes32) {
        return DB_VERSION;
    }

    // -------------------------------------------------------------------------
    // EMERGENCY: when keeper is zero, arbiter can freeze
    // -------------------------------------------------------------------------

    function emergencyFreeze(bytes32 namespaceId_) external {
        if (keeper != address(0) && msg.sender != keeper) revert DB_NotKeeper();
        if (keeper == address(0) && msg.sender != arbiter) revert DB_NotArbiter();
        _namespaceFrozen[namespaceId_] = true;
        emit NamespaceFrozen(namespaceId_, true, block.number);
    }

    function emergencyUnfreeze(bytes32 namespaceId_) external onlyArbiter {
        _namespaceFrozen[namespaceId_] = false;
        emit NamespaceFrozen(namespaceId_, false, block.number);
    }

    // -------------------------------------------------------------------------
    // EXTENDED VIEW: PAIR BY BLOCK RANGE
    // -------------------------------------------------------------------------

    function getPairIdsRegisteredBetween(uint256 fromBlockInclusive, uint256 toBlockInclusive)
        external
        view
        returns (bytes32[] memory outIds)
    {
        uint256 cnt = 0;
        for (uint256 i = 0; i < _pairIds.length; i++) {
            TwinPair storage p = _pairs[_pairIds[i]];
            if (p.registeredAtBlock >= fromBlockInclusive && p.registeredAtBlock <= toBlockInclusive) cnt++;
        }
        outIds = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < _pairIds.length; i++) {
            TwinPair storage p = _pairs[_pairIds[i]];
            if (p.registeredAtBlock >= fromBlockInclusive && p.registeredAtBlock <= toBlockInclusive) {
                outIds[cnt++] = _pairIds[i];
            }
        }
    }

    function getResolvedPairIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids) {
        if (fromIndex > toIndex || toIndex >= _pairIds.length) revert DB_InvalidStripeIndex();
        uint256 len = toIndex - fromIndex + 1;
        uint256 cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            if (_pairs[_pairIds[fromIndex + i]].resolved) cnt++;
        }
        ids = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _pairIds[fromIndex + i];
            if (_pairs[id].resolved) ids[cnt++] = id;
        }
    }

    function getUnresolvedPairIdsInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids) {
        if (fromIndex > toIndex || toIndex >= _pairIds.length) revert DB_InvalidStripeIndex();
        uint256 len = toIndex - fromIndex + 1;
        uint256 cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            if (!_pairs[_pairIds[fromIndex + i]].resolved) cnt++;
        }
        ids = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _pairIds[fromIndex + i];
            if (!_pairs[id].resolved) ids[cnt++] = id;
        }
    }

    function getPairIdsWithBountyInRange(uint256 fromIndex, uint256 toIndex) external view returns (bytes32[] memory ids) {
        if (fromIndex > toIndex || toIndex >= _pairIds.length) revert DB_InvalidStripeIndex();
        uint256 len = toIndex - fromIndex + 1;
        uint256 cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            if (_pairs[_pairIds[fromIndex + i]].bountyWei > 0) cnt++;
        }
        ids = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < len; i++) {
            bytes32 id = _pairIds[fromIndex + i];
            if (_pairs[id].bountyWei > 0) ids[cnt++] = id;
        }
    }

    function countResolvedPairs() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _pairIds.length; i++) {
            if (_pairs[_pairIds[i]].resolved) c++;
        }
        return c;
    }

    function countUnresolvedPairs() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _pairIds.length; i++) {
            if (!_pairs[_pairIds[i]].resolved) c++;
        }
        return c;
    }

    function countPairsWithBounty() external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _pairIds.length; i++) {
            if (_pairs[_pairIds[i]].bountyWei > 0) c++;
        }
        return c;
    }

    function totalBountyWeiAcrossAllPairs() external view returns (uint256 total) {
        for (uint256 i = 0; i < _pairIds.length; i++) {
            total += _pairs[_pairIds[i]].bountyWei;
        }
    }

    function getPairDetails(bytes32 pairId)
        external
        view
        returns (
            bytes32 leftHash_,
            bytes32 rightHash_,
            address binder_,
            uint256 registeredAtBlock_,
            uint8 resolutionOutcome_,
            bool resolved_,
            uint256 strikeCountLeft_,
            uint256 strikeCountRight_,
            uint256 bountyWei_,
            bool bountyClaimed_
        )
    {
        TwinPair storage p = _pairs[pairId];
        if (p.registeredAtBlock == 0) revert DB_PairNotFound();
        leftHash_ = p.leftHash;
        rightHash_ = p.rightHash;
        binder_ = p.binder;
        registeredAtBlock_ = p.registeredAtBlock;
        resolutionOutcome_ = p.resolutionOutcome;
        resolved_ = p.resolved;
        strikeCountLeft_ = p.strikeCountLeft;
        strikeCountRight_ = p.strikeCountRight;
        bountyWei_ = p.bountyWei;
        bountyClaimed_ = p.bountyClaimed;
    }

    function getStripeDetails(bytes32 stripeId)
        external
        view
        returns (
            bytes32 anchorHash_,
            address owner_,
            uint256 createdAtBlock_,
            bytes32 linkedPairId_,
            bool linked_
        )
    {
        Stripe storage s = _stripes[stripeId];
        if (s.createdAtBlock == 0) revert DB_StripeNotFound();
        anchorHash_ = s.anchorHash;
        owner_ = s.owner;
        createdAtBlock_ = s.createdAtBlock;
        linkedPairId_ = s.linkedPairId;
        linked_ = s.linked;
    }

    function getLinkedStripeIdsForPair(bytes32 pairId) external view returns (bytes32[] memory stripeIdsOut) {
        uint256 cnt = 0;
        for (uint256 i = 0; i < _stripeIds.length; i++) {
            if (_stripes[_stripeIds[i]].linkedPairId == pairId) cnt++;
        }
        stripeIdsOut = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < _stripeIds.length; i++) {
            bytes32 sid = _stripeIds[i];
            if (_stripes[sid].linkedPairId == pairId) stripeIdsOut[cnt++] = sid;
        }
    }

    function getStripeIdsByOwner(address owner) external view returns (bytes32[] memory outIds) {
        uint256 cnt = 0;
        for (uint256 i = 0; i < _stripeIds.length; i++) {
            if (_stripes[_stripeIds[i]].owner == owner) cnt++;
        }
        outIds = new bytes32[](cnt);
        cnt = 0;
        for (uint256 i = 0; i < _stripeIds.length; i++) {
            bytes32 sid = _stripeIds[i];
            if (_stripes[sid].owner == owner) outIds[cnt++] = sid;
        }
    }

    function getStripeCountByOwner(address owner) external view returns (uint256) {
        uint256 c = 0;
        for (uint256 i = 0; i < _stripeIds.length; i++) {
            if (_stripes[_stripeIds[i]].owner == owner) c++;
        }
        return c;
    }

    function getPairIdsByBinderPaginated(address binder, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory ids)
    {
        bytes32[] memory all = _pairIdsByBinder[binder];
        if (offset >= all.length) return new bytes32[](0);
        uint256 end = offset + limit;
        if (end > all.length) end = all.length;
        uint256 len = end - offset;
        ids = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            ids[i] = all[offset + i];
        }
    }

    function getPairIdAtIndexUnchecked(uint256 index) external view returns (bytes32) {
        return _pairIds[index];
    }

    function getStripeIdAtIndexUnchecked(uint256 index) external view returns (bytes32) {
        return _stripeIds[index];
    }

    function getStrikerLeftAt(bytes32 pairId, uint256 index) external view returns (address) {
        address[] storage arr = _strikersLeft[pairId];
        if (index >= arr.length) revert DB_InvalidStripeIndex();
        return arr[index];
    }

    function getStrikerRightAt(bytes32 pairId, uint256 index) external view returns (address) {
        address[] storage arr = _strikersRight[pairId];
        if (index >= arr.length) revert DB_InvalidStripeIndex();
        return arr[index];
    }

    function getStrikerLeftCount(bytes32 pairId) external view returns (uint256) {
        return _strikersLeft[pairId].length;
    }

    function getStrikerRightCount(bytes32 pairId) external view returns (uint256) {
        return _strikersRight[pairId].length;
    }

    function contractBalanceWei() external view returns (uint256) {
        return address(this).balance;
    }

    function getImmutables()
        external
        view
        returns (
            address keeper_,
