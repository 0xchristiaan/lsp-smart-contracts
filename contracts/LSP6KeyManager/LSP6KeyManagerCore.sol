// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.6;

// modules
import "@erc725/smart-contracts/contracts/ERC725Y.sol";
import "@erc725/smart-contracts/contracts/ERC725.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Storage.sol";

// interfaces
import "./ILSP6KeyManager.sol";

// libraries
import "../Utils/LSP2Utils.sol";
import "@erc725/smart-contracts/contracts/utils/ERC725Utils.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// constants
import "./LSP6Constants.sol";
import "@erc725/smart-contracts/contracts/constants.sol";

/**
 * @title Contract acting as a controller of an ERC725 Account, using permissions stored in the ERC725Y storage
 * @author Fabian Vogelsteller, Jean Cavallera
 * @dev all the permissions can be set on the ERC725 Account using `setData(...)` with the keys constants below
 */
abstract contract LSP6KeyManagerCore is ILSP6KeyManager, ERC165Storage {
    using LSP2Utils for bytes12;
    using ERC725Utils for ERC725Y;
    using ECDSA for bytes32;

    ERC725 public account;
    mapping(address => mapping(uint256 => uint256)) internal _nonceStore;

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165Storage)
        returns (bool)
    {
        return interfaceId == _INTERFACE_ID_ERC1271 || super.supportsInterface(interfaceId);
    }

    /**
     * Get latest nonce for `_from` in a specific channel (`_channelId`)
     *
     * @param _from caller address
     * @param _channel channel id
     */
    function getNonce(address _from, uint256 _channel) public view override returns (uint256) {
        uint128 nonceId = uint128(_nonceStore[_from][_channel]);
        return (uint256(_channel) << 128) | nonceId;
    }

    /**
     * @notice Checks if an owner signed `_data`.
     * ERC1271 interface.
     *
     * @param _hash hash of the data signed//Arbitrary length data signed on the behalf of address(this)
     * @param _signature owner's signature(s) of the data
     */
    function isValidSignature(bytes32 _hash, bytes memory _signature)
        public
        view
        override
        returns (bytes4 magicValue)
    {
        address recoveredAddress = ECDSA.recover(_hash, _signature);
        return
            (_PERMISSION_SIGN & _getAddressPermissions(recoveredAddress)) == _PERMISSION_SIGN
                ? _INTERFACE_ID_ERC1271
                : _ERC1271FAILVALUE;
    }

    /**
     * @dev execute the payload _data on the ERC725 Account
     * @param _data obtained via encodeABI() in web3
     * @return result_ the data being returned by the ERC725 Account
     */
    function execute(bytes calldata _data) external payable override returns (bytes memory) {
        _verifyPermissions(msg.sender, _data);

        (bool success, bytes memory result_) = address(account).call{
            value: msg.value,
            gas: gasleft()
        }(_data);

        if (!success) {
            /* solhint-disable */
            if (result_.length < 68) revert();
            assembly {
                result_ := add(result_, 0x04)
            }
            revert(abi.decode(result_, (string)));
            /* solhint-enable */
        }

        emit Executed(msg.value, _data);
        return result_.length > 0 ? abi.decode(result_, (bytes)) : result_;
    }

    /**
     * @dev allows anybody to execute given they have a signed message from an executor
     * @param _signedFor this KeyManager
     * @param _nonce the address' nonce (in a specific `_channel`), obtained via `getNonce(...)`. Used to prevent replay attack
     * @param _data obtained via encodeABI() in web3
     * @param _signature bytes32 ethereum signature
     * @return result_ the data being returned by the ERC725 Account
     */
    function executeRelayCall(
        address _signedFor,
        uint256 _nonce,
        bytes calldata _data,
        bytes memory _signature
    ) external payable override returns (bytes memory) {
        require(
            _signedFor == address(this),
            "KeyManager:executeRelayCall: Message not signed for this keyManager"
        );

        bytes memory blob = abi.encodePacked(
            address(this), // needs to be signed for this keyManager
            _nonce,
            _data
        );

        address signer = keccak256(blob).toEthSignedMessageHash().recover(_signature);

        require(_isValidNonce(signer, _nonce), "KeyManager:executeRelayCall: Incorrect nonce");

        // increase nonce after successful verification
        _nonceStore[signer][_nonce >> 128]++;

        _verifyPermissions(signer, _data);

        (bool success, bytes memory result_) = address(account).call{value: 0, gas: gasleft()}(
            _data
        );

        if (!success) {
            /* solhint-disable */
            if (result_.length < 68) revert();
            assembly {
                result_ := add(result_, 0x04)
            }
            revert(abi.decode(result_, (string)));
            /* solhint-enable */
        }

        emit Executed(msg.value, _data);
        return result_.length > 0 ? abi.decode(result_, (bytes)) : result_;
    }

    /**
     * @dev "idx" is a 256bits (unsigned) integer, where:
     *          - the 128 leftmost bits = channelId
     *      and - the 128 rightmost bits = nonce within the channel
     * @param _from caller address
     * @param _idx (channel id + nonce within the channel)
     */
    function _isValidNonce(address _from, uint256 _idx) internal view returns (bool) {
        // idx % (1 << 128) = nonce
        // (idx >> 128) = channel
        // equivalent to: return (nonce == _nonceStore[_from][channel]
        return (_idx % (1 << 128)) == (_nonceStore[_from][_idx >> 128]);
    }

    /**
     * @dev verify the permissions of the _from address that want to interact with the `account`
     * @param _from the address making the request
     * @param _data the payload that will be run on `account`
     */
    function _verifyPermissions(address _from, bytes calldata _data) internal view {
        bytes4 erc725Function = bytes4(_data[:4]);

        if (erc725Function == account.setData.selector) {
            _verifyCanSetData(_from, _data);
        } else if (erc725Function == account.execute.selector) {
            _verifyCanExecute(_from, _data);

            address to = address(bytes20(_data[48:68]));
            _verifyAllowedAddress(_from, to);

            if (_data.length >= 168) {
                bytes4 functionCalled = bytes4(_data[164:168]);
                _verifyAllowedFunction(_from, functionCalled);
            }
        } else if (erc725Function == account.transferOwnership.selector) {
            bytes32 permissions = _getAddressPermissions(_from);
            require(
                _hasPermission(_PERMISSION_CHANGEOWNER, permissions),
                "KeyManager:_verifyPermissions: Not authorized to transfer ownership"
            );
        } else {
            revert("KeyManager:_verifyPermissions: unknown function selector on ERC725 account");
        }
    }

    function _verifyCanSetData(address _from, bytes calldata _data) internal view {
        bytes32 permissions = _getAddressPermissions(_from);

        uint256 keyCount = uint256(bytes32(_data[68:100]));
        uint256 pointer = 100;

        // loop through the keys
        for (uint256 ii = 0; ii < keyCount; ii++) {
            bytes32 key = bytes32(_data[pointer:pointer + 32]);

            // check if the key is related to setting permissions
            if (bytes8(key) == _SET_PERMISSIONS) {
                bool isNewAddress = bytes32(ERC725Y(account).getDataSingle(key)) == bytes32(0);

                isNewAddress
                    ? require(
                        _hasPermission(_PERMISSION_ADDPERMISSIONS, permissions),
                        "KeyManager:_verifyCanSetData: not authorized to ADDPERMISSIONS"
                    )
                    : require(
                        _hasPermission(_PERMISSION_CHANGEPERMISSIONS, permissions),
                        "KeyManager:_verifyCanSetData: not authorized to CHANGEPERMISSIONS"
                    );
            } else {
                require(
                    _hasPermission(_PERMISSION_SETDATA, permissions),
                    "KeyManager:_verifyCanSetData: not authorized to SETDATA"
                );
            }

            pointer += 32; // move calldata pointer
        }
    }

    function _verifyCanExecute(address _from, bytes calldata _data) internal view {
        bytes32 permissions = _getAddressPermissions(_from);

        uint256 operationType = uint256(bytes32(_data[4:36]));
        uint256 value = uint256(bytes32(_data[68:100]));

        require(
            operationType != 4,
            "KeyManager:_verifyCanExecute: operation 4 `DELEGATECALL` not supported"
        );

        require(
            operationType < 5, // Check for CALL, DEPLOY or STATICCALL
            "KeyManager:_verifyCanExecute: invalid operation type"
        );

        if (operationType == 0) {
            require(
                _hasPermission(_PERMISSION_CALL, permissions),
                "KeyManager:_verifyCanExecute: not authorized to CALL"
            );
        }

        if (operationType == 1 || operationType == 2) {
            require(
                _hasPermission(_PERMISSION_DEPLOY, permissions),
                "KeyManager:_verifyCanExecute: not authorized to DEPLOY"
            );
        }

        if (operationType == 3) {
            require(
                _hasPermission(_PERMISSION_STATICCALL, permissions),
                "KeyManager:_verifyCanExecute: not authorized to STATICCALL"
            );
        }

        if (value > 0) {
            require(
                _hasPermission(_PERMISSION_TRANSFERVALUE, permissions),
                "KeyManager:_verifyCanExecute: not authorized to TRANSFERVALUE"
            );
        }
    }

    function _verifyAllowedAddress(address _from, address _to) internal view {
        bytes memory allowedAddresses = ERC725Y(account).getDataSingle(
            LSP2Utils.generateBytes20MappingWithGroupingKey(
                _ADDRESS_ALLOWEDADDRESSES,
                bytes20(_from)
            )
        );

        if (allowedAddresses.length == 0) return;

        address[] memory allowedAddressesList = abi.decode(allowedAddresses, (address[]));

        for (uint256 ii = 0; ii < allowedAddressesList.length; ii++) {
            if (_to == allowedAddressesList[ii]) return;
        }
        revert("KeyManager:_verifyAllowedAddress: Not authorized to interact with this address");
    }

    function _verifyAllowedFunction(address _from, bytes4 _functionSelector) internal view {
        bytes memory allowedFunctions = ERC725Y(account).getDataSingle(
            LSP2Utils.generateBytes20MappingWithGroupingKey(
                _ADDRESS_ALLOWEDFUNCTIONS,
                bytes20(_from)
            )
        );

        if (allowedFunctions.length == 0) return;

        bytes4[] memory allowedFunctionsList = abi.decode(allowedFunctions, (bytes4[]));

        for (uint256 ii = 0; ii < allowedFunctionsList.length; ii++) {
            if (_functionSelector == allowedFunctionsList[ii]) return;
        }
        revert("KeyManager:_verifyAllowedFunction: not authorised to run this function");
    }

    function _getAddressPermissions(address _address) internal view returns (bytes32) {
        bytes memory fetchResult = ERC725Y(account).getDataSingle(
            LSP2Utils.generateBytes20MappingWithGroupingKey(_ADDRESS_PERMISSIONS, bytes20(_address))
        );

        if (fetchResult.length == 0) {
            revert("KeyManager:_getAddressPermissions: no permissions set for this address");
        }

        bytes32 storedPermission;
        // solhint-disable-next-line
        assembly {
            storedPermission := mload(add(fetchResult, 32))
        }

        return storedPermission;
    }

    function _hasPermission(bytes32 _permission, bytes32 _addressPermission)
        internal
        pure
        returns (bool)
    {
        return (_permission & _addressPermission) == _permission ? true : false;
    }
}
