// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title MulticallerWithSigner
 * @author vectorized.eth
 * @notice Contract that allows for efficient aggregation of multiple calls
 *         in a single transaction, while "forwarding" the `signer`.
 */
contract MulticallerWithSigner {
    // =============================================================
    //                            EVENTS
    // =============================================================

    /**
     * @dev Emitted when the `nonces` of `signer` are invalidated.
     */
    event NoncesInvalidated(address indexed signer, uint256[] nonces);

    /**
     * @dev Emitted when the nonce salt of `signer` is incremented.
     */
    event NonceSaltIncremented(address indexed signer, uint256 newNonceSalt);

    /**
     * @dev `keccak256("NoncesInvalidated(address,uint256[])")`.
     */
    uint256 private constant _NONCES_INVALIDATED_EVENT_SIGNATURE =
        0xc45e3a0dd412bcad8d62398d74d66b1c8449f38beb10da275e4da0c6d3a811a4;

    /**
     * @dev `keccak256("NonceSaltIncremented(address,uint256)")`.
     */
    uint256 private constant _NONCE_SALT_INCREMENTED_EVENT_SIGNATURE =
        0x997a42216df16c8b9e7caf2fc71c59dba956f1f2b12320f87a80a5879464217d;

    // =============================================================
    //                           CONSTANTS
    // =============================================================

    /**
     * @dev For EIP-712 signature digest calculation.
     * `keccak256("AggregateWithSigner(string message,address[] targets,bytes[] data,uint256[] values,uint256 nonce,uint256 nonceSalt)")`.
     */
    bytes32 public constant AGGREGATE_WITH_SIGNER_TYPEHASH =
        0xc4d2f044d99707794280032fc14879a220a3f7dc766d75100809624f91d69e97;

    // =============================================================
    //                            ERRORS
    // =============================================================

    /**
     * @dev The lengths of the input arrays are not the same.
     */
    error ArrayLengthsMismatch();

    /**
     * @dev This function does not support reentrancy.
     */
    error Reentrancy();

    /**
     * @dev The signature is invalid.
     */
    error InvalidSignature();

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    constructor() payable {
        assembly {
            // Throughout this code, we will abuse returndatasize
            // in place of zero anywhere before a call to save a bit of gas.
            // We will use storage slot zero to store the caller at
            // bits [0..159] and reentrancy guard flag at bit 160.
            sstore(returndatasize(), shl(160, 1))
        }
    }

    // =============================================================
    //                    AGGREGATION OPERATIONS
    // =============================================================

    /**
     * @dev Returns the signer passed into `aggregateWithSigner` on this contract.
     *      The value is always the zero address outside a transaction.
     */
    receive() external payable {
        assembly {
            mstore(returndatasize(), and(sub(shl(160, 1), 1), sload(returndatasize())))
            return(returndatasize(), 0x20)
        }
    }

    /**
     * @dev Aggregates multiple calls in a single transaction.
     *      This method will store the `signer` temporarily
     *      for the span of its execution.
     *      This method does not support reentrancy.
     *      Emits a `NoncesInvalidated(signer, [nonce])` event.
     * @param message   A human readable message on what the signature is about.
     * @param targets   An array of addresses to call.
     * @param data      An array of calldata to forward to the targets.
     * @param values    How much ETH to forward to each target.
     * @param nonce     The nonce for the signature.
     * @param nonceSalt The salt for the nonce.
     * @param signer    The signer for the signature.
     * @param signature The signature by the signer.
     * @return An array of the returndata from each call.
     */
    function aggregateWithSigner(
        string memory message,
        address[] calldata targets,
        bytes[] calldata data,
        uint256[] calldata values,
        uint256 nonce,
        uint256 nonceSalt,
        address signer,
        bytes calldata signature
    ) external payable returns (bytes[] memory) {
        assembly {
            if iszero(and(eq(targets.length, data.length), eq(data.length, values.length))) {
                // Store the function selector of `ArrayLengthsMismatch()`.
                mstore(returndatasize(), 0x3b800a46)
                // Revert with (offset, size).
                revert(0x1c, 0x04)
            }

            if iszero(shr(160, sload(returndatasize()))) {
                // Store the function selector of `Reentrancy()`.
                mstore(returndatasize(), 0xab143c06)
                // Revert with (offset, size).
                revert(0x1c, 0x04)
            }

            // Multiply `data.length` by 0x20. This is the byte length of `targets`, `data`, values`.
            data.length := shl(5, data.length)

            /* --------------------- CHECK SIGNATURE -------------------- */

            // Store `AGGREGATE_WITH_SIGNER_TYPEHASH`.
            mstore(returndatasize(), AGGREGATE_WITH_SIGNER_TYPEHASH)
            // Compute and store `keccak256(abi.encodePacked(message))`.
            mstore(0x20, keccak256(add(message, 0x20), mload(message)))
            // Compute and store `keccak256(abi.encodePacked(targets))`.
            calldatacopy(0x40, targets.offset, data.length)
            mstore(0x40, keccak256(0x40, data.length))
            // Compute and store
            // `keccak256(abi.encodePacked(keccak256(data[0]), .., keccak256(data[n-1])))`.
            for { let i := returndatasize() } iszero(eq(i, data.length)) { i := add(i, 0x20) } {
                let o := add(data.offset, calldataload(add(data.offset, i)))
                let p := add(0x60, i)
                calldatacopy(p, add(o, 0x20), calldataload(o))
                mstore(p, keccak256(p, calldataload(o)))
            }
            mstore(0x60, keccak256(0x60, data.length))
            // Compute and store `keccak256(abi.encodePacked(values))`.
            calldatacopy(0x80, values.offset, data.length)
            mstore(0x80, keccak256(0x80, data.length))
            // Store `nonce` and `nonceSalt`.
            mstore(0xa0, nonce)
            mstore(0xc0, nonceSalt)
            mstore(0x40, keccak256(returndatasize(), 0xe0)) // Store the struct hash.

            // `keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.
            mstore(0x80, 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f)
            // `keccak256("MulticallerWithSigner")`.
            mstore(0xa0, 0x301013e8a31863902646dc218ecd889c37491c2967a8104d5ff1cf42af0f9ea4)
            // `keccak256("1")`.
            mstore(0xc0, 0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6)
            mstore(0xe0, chainid())
            mstore(0x100, address())

            // Compute the digest.
            mstore(returndatasize(), 0x1901) // Store "\x19\x01".
            mstore(0x20, keccak256(0x80, 0xa0)) // Store the domain separator.

            // Recover the signer from the `digest` and `signature`.
            mstore(returndatasize(), keccak256(0x1e, 0x42)) // `digest`.
            mstore(0x20, byte(returndatasize(), calldataload(add(signature.offset, 0x40)))) // `v`.
            calldatacopy(0x40, signature.offset, 0x40) // Copy `r` and `s`.
            pop(
                staticcall(
                    gas(), // Amount of gas left for the transaction.
                    and(
                        // If the signature is exactly 65 bytes in length.
                        eq(signature.length, 65),
                        // If `s` in lower half order, such that the signature is not malleable.
                        lt(
                            mload(0x60),
                            0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a1
                        )
                    ), // Address of `ecrecover`.
                    returndatasize(), // Start of input.
                    0x80, // Size of input.
                    returndatasize(), // Start of output.
                    0x20 // Size of output.
                )
            )
            // `returndatasize()` will be `0x20` upon success, and `0x00` otherwise.
            let recoverySuccess := mul(returndatasize(), eq(mload(0x00), signer))

            // Check `nonce` and `nonceSalt`.
            mstore(0x00, signer)
            mstore(0x20, shr(8, nonce))
            let bucketSlot := keccak256(0x0c, 0x34)
            let bucketValue := sload(bucketSlot)
            let bit := shl(and(0xff, nonce), 1)
            let saltInvalid := xor(sload(or(shl(96, signer), 1)), nonceSalt)
            if or(iszero(recoverySuccess), or(and(bit, bucketValue), saltInvalid)) {
                mstore(0x00, 0x8baa579f) // `InvalidSignature()`.
                revert(0x1c, 0x04)
            }
            // Invalidate the nonce.
            sstore(bucketSlot, or(bucketValue, bit))

            // Emit `NoncesInvalidated(signer, [nonce])`.
            mstore(0x00, 0x20)
            mstore(0x20, 1)
            mstore(0x40, nonce)
            log2(0x00, 0x60, _NONCES_INVALIDATED_EVENT_SIGNATURE, signer)

            /* -------------------- PERFORM AGGREGATE ------------------- */

            // Early return if no data.
            if iszero(data.length) {
                // Slot 0x00's value is already 0x20.
                mstore(0x20, data.length) // Store `data.length` into `results`.
                return(0x00, 0x40)
            }

            // Set the signer slot temporarily for the span of this transaction.
            sstore(0x00, signer)

            let results := 0x40
            // Copy the offsets from calldata into memory.
            calldatacopy(results, data.offset, data.length)
            // Offset into `results`.
            let resultsOffset := data.length
            // Pointer to the end of `results`.
            let end := add(results, data.length)

            // Abuse `signature.length` to store `targets.offset`,
            // and `signature.offset` to store `values.offset` to avoid stack too deep.
            signature.length := targets.offset
            signature.offset := values.offset

            for {} 1 {} {
                // The offset of the current bytes in the calldata.
                let o := add(data.offset, mload(results))
                let memPtr := add(resultsOffset, 0x40)
                // Copy the current bytes from calldata to the memory.
                calldatacopy(
                    memPtr,
                    add(o, 0x20), // The offset of the current bytes' bytes.
                    calldataload(o) // The length of the current bytes.
                )
                if iszero(
                    call(
                        gas(), // Remaining gas.
                        calldataload(signature.length), // Address to call.
                        calldataload(signature.offset), // ETH to send.
                        memPtr, // Start of input calldata in memory.
                        calldataload(o), // Size of input calldata.
                        0x00, // We will use returndatacopy instead.
                        0x00 // We will use returndatacopy instead.
                    )
                ) {
                    // Bubble up the revert if the call reverts.
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
                // Advance the `targets.offset`.
                signature.length := add(signature.length, 0x20)
                // Advance the `values.offset`.
                signature.offset := add(signature.offset, 0x20)
                // Append the current `resultsOffset` into `results`.
                mstore(results, resultsOffset)
                results := add(results, 0x20)
                // Append the returndatasize, and the returndata.
                mstore(memPtr, returndatasize())
                returndatacopy(add(memPtr, 0x20), 0x00, returndatasize())
                // Advance the `resultsOffset` by `returndatasize() + 0x20`,
                // rounded up to the next multiple of 0x20.
                resultsOffset := and(add(add(resultsOffset, returndatasize()), 0x3f), not(0x1f))
                if eq(results, end) { break }
            }
            // Slot 0x00's value is already 0x20.
            mstore(0x20, targets.length) // Store `targets.length` into `results`.

            // Restore the `signer` slot.
            sstore(0, shl(160, 1))
            // Direct return.
            return(0x00, add(resultsOffset, 0x40))
        }
    }

    // =============================================================
    //                     SIGNATURE OPERATIONS
    // =============================================================

    /**
     * @dev Invalidates the `nonces` of `msg.sender`.
     *      Emits a `NoncesInvalidated(msg.sender, nonces)` event.
     * @param nonces An array of nonces to invalidate.
     */
    function invalidateNonces(uint256[] calldata nonces) external {
        assembly {
            mstore(returndatasize(), caller())
            // Iterate through all the nonces and set their boolean values in the storage.
            let end := shl(5, nonces.length)
            for { let i := returndatasize() } iszero(eq(i, end)) { i := add(i, 0x20) } {
                let nonce := calldataload(add(nonces.offset, i))
                mstore(0x20, shr(8, nonce))
                let bucketSlot := keccak256(0x0c, 0x34)
                sstore(bucketSlot, or(sload(bucketSlot), shl(and(0xff, nonce), 1)))
            }
            // Emit `NoncesInvalidated(msg.sender, nonces)`.
            mstore(returndatasize(), 0x20)
            mstore(0x20, nonces.length)
            calldatacopy(0x40, nonces.offset, end)
            log2(returndatasize(), add(0x40, end), _NONCES_INVALIDATED_EVENT_SIGNATURE, caller())
        }
    }

    /**
     * @dev Returns whether each of the `nonces` of `signer` has been invalidated.
     * @param signer The signer of the signature.
     * @param nonces An array of nonces.
     * @return A bool array representing whether each nonce has been invalidated.
     */
    function noncesInvalidated(address signer, uint256[] calldata nonces)
        external
        view
        returns (bool[] memory)
    {
        assembly {
            mstore(returndatasize(), signer)
            // Iterate through all the nonces and append their boolean values.
            let end := shl(5, nonces.length)
            for { let i := returndatasize() } iszero(eq(i, end)) { i := add(i, 0x20) } {
                let nonce := calldataload(add(nonces.offset, i))
                mstore(0x20, shr(8, nonce))
                let bit := and(1, shr(and(0xff, nonce), sload(keccak256(0x0c, 0x34))))
                mstore(add(0x40, i), bit)
            }
            mstore(returndatasize(), 0x20) // Store the memory offset of the `results`.
            mstore(0x20, nonces.length) // Store `data.length` into `results`.
            return(returndatasize(), add(0x40, end))
        }
    }

    /**
     * @dev Increments the nonce salt of `msg.sender`.
     *      Will not make invalidated nonces available for use.
     *      Emits a `NonceSaltIncremented(msg.sender, newNonceSalt)` event.
     * @return The new nonce salt.
     */
    function incrementNonceSalt() external returns (uint256) {
        assembly {
            let nonceSaltSlot := or(shl(96, caller()), 1)
            let newNonceSalt := add(1, sload(nonceSaltSlot))
            sstore(nonceSaltSlot, newNonceSalt)
            // Emit `NonceSaltIncremented(msg.sender, newNonceSalt)`.
            mstore(returndatasize(), newNonceSalt)
            log2(returndatasize(), 0x20, _NONCE_SALT_INCREMENTED_EVENT_SIGNATURE, caller())
            return(returndatasize(), 0x20)
        }
    }

    /**
     * @dev Returns the nonce salt of `signer`.
     * @param signer The signer of the signature.
     * @return The current nonce salt of `signer`.
     */
    function nonceSaltOf(address signer) external view returns (uint256) {
        assembly {
            mstore(returndatasize(), sload(or(shl(96, signer), 1)))
            return(returndatasize(), 0x20)
        }
    }

    /**
     * @dev Returns the EIP-712 domain information, as specified in
     *       [EIP-5267](https://eips.ethereum.org/EIPS/eip-5267).
     * @return fields            `hex"0f"` (`0b01111`).
     * @return name              `"MulticallerWithSender"`.
     * @return version           `"1"`.
     * @return chainId           The chain ID which this contract is on.
     * @return verifyingContract `address(this)`, the address of this contract.
     * @return salt              `bytes32(0)` (not used).
     * @return extensions        `[]` (not used).
     */
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        fields = hex"0f"; // `0b01111`.
        name = "MulticallerWithSigner";
        version = "1";
        chainId = block.chainid;
        verifyingContract = address(this);
        salt = salt; // `bytes32(0)`.
        extensions = extensions; // `new uint256[](0)`.
    }
}
