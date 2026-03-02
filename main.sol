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
