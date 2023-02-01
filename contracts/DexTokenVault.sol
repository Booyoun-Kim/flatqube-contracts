pragma ton-solidity >= 0.62.0;

pragma AbiHeader time;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "@broxus/contracts/contracts/libraries/MsgFlag.sol";

import "tip3/contracts/interfaces/ITokenRoot.sol";
import "tip3/contracts/interfaces/ITokenWallet.sol";

import "./abstract/DexContractBase.sol";

import "./interfaces/IDexAccount.sol";
import "./interfaces/IDexBasePool.sol";
import "./interfaces/IDexTokenVault.sol";
import "./interfaces/IDexVault.sol";

import "./libraries/DexErrors.sol";
import "./libraries/DexGas.sol";
import "./libraries/DexOperationTypes.sol";

contract DexTokenVault is
    DexContractBase,
    IDexTokenVault
{
    address private _root;
    address private _legacyVault;
    uint32 private _version;
    address private _tokenRoot;
    address private _tokenWallet;
    address private _firstCallbackRecipient;
    address private _firstCallbackRemainingGasTo;

    function _dexRoot() internal view override returns (address) {
        return _root;
    }

    modifier onlyDexRoot() {
        require(_root.value != 0 && msg.sender == _root, DexErrors.NOT_MY_OWNER);
        _;
    }

    modifier onlyTokenRoot() {
        require(_tokenRoot.value != 0 && msg.sender == _tokenRoot, DexErrors.WRONG_TOKEN_ROOT);
        _;
    }

    modifier reserve(uint128 _reserve) {
        tvm.rawReserve(_reserve, 0);
        _;
    }

    function _getTargetBalanceInternal()
        internal
        view
        returns (uint128)
    {
        return DexGas.VAULT_INITIAL_BALANCE;
    }

    receive() external pure { revert(); }

    fallback() external pure { revert(); }

    constructor() public { revert(); }

    function redeploy(
        TvmCell /* _code */,
        uint32 /* _vaultCodeVersionInRoot */,
        address /* _callbackRecipient */,
        address _remainingGasTo
    )
        external
        override
        functionID(0x15a038fb)
        reserve(_getTargetBalanceInternal())
        onlyDexRoot
    {
        _remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED,
            bounce: false
        });
    }

    function getDexRoot() external view override responsible returns (address) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _root;
    }

    function getVersion() external view override responsible returns (uint32) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _version;
    }

    function getPlatformCode() external view override responsible returns (TvmCell) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } platform_code;
    }

    function getTokenRoot() external view override responsible returns (address) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _tokenRoot;
    }

    function getTokenWallet() external view override responsible returns (address) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _tokenWallet;
    }

    function getLegacyVault() external view override responsible returns (address) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _legacyVault;
    }

    function getTargetBalance() external view override responsible returns (uint128) {
        return {
            value: 0,
            flag: MsgFlag.REMAINING_GAS,
            bounce: false
        } _getTargetBalanceInternal();
    }

    function withdraw(
        uint64 _callId,
        uint128 _amount,
        address _recipientAddress,
        uint128 _deployWalletGrams,
        address _accountOwner,
        uint32 /* _accountVersion */,
        address _remainingGasTo
    )
        external
        override
        reserve(_getTargetBalanceInternal())
        onlyAccount(_accountOwner)
    {
        emit WithdrawTokens({
            amount: _amount,
            accountOwner: _accountOwner,
            recipientAddress: _recipientAddress
        });

        TvmCell empty;

        ITokenWallet(_tokenWallet)
            .transfer{
                value: DexGas.TRANSFER_TOKENS_VALUE + _deployWalletGrams,
                flag: MsgFlag.SENDER_PAYS_FEES,
                bounce: false
            }(
                _amount,
                _recipientAddress,
                _deployWalletGrams,
                _remainingGasTo,
                false,
                empty
            );

        IDexAccount(msg.sender)
            .successCallback{
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED,
                bounce: false
            }(_callId);
    }

    function transfer(
        uint128 _amount,
        address _recipientAddress,
        uint128 _deployWalletGrams,
        bool _notifyReceiver,
        TvmCell _payload,
        address[] _roots,
        uint32 /* _pairVersion */,
        address _remainingGasTo
    )
        external
        override
        reserve(_getTargetBalanceInternal())
    {
        emit PairTransferTokens({
            amount: _amount,
            roots: _roots,
            recipientAddress: _recipientAddress
        });

        ITokenWallet(_tokenWallet)
            .transfer{
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED,
                bounce: false
            }(
                _amount,
                _recipientAddress,
                _deployWalletGrams,
                _remainingGasTo,
                _notifyReceiver,
                _payload
            );
    }

    function referralFeeTransfer(
        uint128 _amount,
        address _referrer,
        address _referral,
        address[] _roots
    )
        external
        override
        reserve(_getTargetBalanceInternal())
        onlyPool(_roots)
    {
        TvmBuilder builder;

        builder.store(DexOperationTypes.REFERRAL_FEE);
        builder.storeRef(abi.encode(_roots, _referrer, _referral));

        ITokenWallet(_tokenWallet)
            .transfer{
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED,
                bounce: false
            }(
                _amount,
                _legacyVault,
                DexGas.DEPLOY_EMPTY_WALLET_GRAMS,
                _referral,
                true,
                builder.toCell()
            );
    }

    function resetGas(address _remainingGasTo)
        external
        override
        view
        reserve(_getTargetBalanceInternal())
        onlyDexRoot
    {
        _remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
            bounce: false
        });
    }

    function upgrade(
        TvmCell _newCode,
        uint32 _newVersion,
        address _remainingGasTo
    ) external override reserve(_getTargetBalanceInternal()) onlyDexRoot {
        TvmBuilder builder;
        TvmBuilder params;

        params.store(_tokenRoot);
        params.store(_tokenWallet);
        params.store(_firstCallbackRemainingGasTo);

        builder.store(_root);
        builder.store(_firstCallbackRecipient);
        builder.store(_version);
        builder.store(_newVersion);
        builder.store(_remainingGasTo);

        builder.store(platform_code);
        builder.store(params);

        tvm.setcode(_newCode);
        tvm.setCurrentCode(_newCode);

        onCodeUpgrade(builder.toCell());
    }

    function onCodeUpgrade(TvmCell _data) private reserve(_getTargetBalanceInternal()) {
        tvm.resetStorage();

        TvmSlice slice = _data.toSlice();

        (
            address root,
            address legacyVault,
            uint32 previousVersion
        ) = slice.decode(
            address,
            address,
            uint32
        );

        _root = root;
        _legacyVault = legacyVault;

        if (previousVersion == 0) {
            _onPlatformUpgrade(_data);
        } else {
            _onUpgrade(_data);
        }
    }

    function _onPlatformUpgrade(TvmCell _data) private {
        TvmSlice slice = _data.toSlice();

        (
            /* address root */,
            /* address firstCallbackRecipient */,
            /* uint32 previousVersion */,
            uint32 currentVersion,
            address remainingGasTo
        ) = slice.decode(
            address,
            address,
            uint32,
            uint32,
            address
        );

        _version = currentVersion;
        _firstCallbackRemainingGasTo = remainingGasTo;
        platform_code = slice.loadRef();
        _tokenRoot = slice.loadRefAsSlice().decode(address);

        emit TokenVaultCodeUpgraded({
            currentVersion: currentVersion,
            previousVersion: 0
        });

        _deployTokenWallet();

        remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
            bounce: false
        });
    }

    function _onUpgrade(TvmCell _data) private {
        TvmSlice slice = _data.toSlice();

        (
            /* address root */,
            /* address firstCallbackRecipient */,
            uint32 previousVersion,
            uint32 currentVersion,
            address remainingGasTo
        ) = slice.decode(
            address,
            address,
            uint32,
            uint32,
            address
        );

        _version = currentVersion;
        platform_code = slice.loadRef();
        (
            _tokenRoot,
            _tokenWallet,
            _firstCallbackRemainingGasTo
        ) = slice.loadRefAsSlice().decode(
            address,
            address,
            address
        );

        emit TokenVaultCodeUpgraded({
            currentVersion: currentVersion,
            previousVersion: previousVersion
        });

        remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
            bounce: false
        });
    }

    function _deployTokenWallet() private {
        ITokenRoot(_tokenRoot)
            .deployWallet{
                value: DexGas.DEPLOY_EMPTY_WALLET_VALUE,
                flag: MsgFlag.SENDER_PAYS_FEES,
                callback: DexTokenVault.onTokenWallet
            }(address(this), DexGas.DEPLOY_EMPTY_WALLET_GRAMS);
    }

    function onTokenWallet(address _wallet)
        external
        reserve(_getTargetBalanceInternal())
        onlyTokenRoot
    {
        _tokenWallet = _wallet;

        _firstCallbackRemainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED,
            bounce: false
        });
    }
}
