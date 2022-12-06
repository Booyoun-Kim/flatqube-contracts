pragma ton-solidity >= 0.57.0;

pragma AbiHeader time;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "@broxus/contracts/contracts/libraries/MsgFlag.sol";

import "ton-eth-bridge-token-contracts/contracts/interfaces/ITokenRoot.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/ITokenWallet.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/IBurnableByRootTokenRoot.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/IBurnableTokenWallet.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/IAcceptTokensTransferCallback.sol";

import "./abstract/ManagerAddress.sol";
import "./abstract/DexContractBase.sol";
import "./abstract/TWAPOracle.sol";

import "./interfaces/IUpgradableByRequest.sol";
import "./interfaces/IDexPair.sol";
import "./interfaces/ISuccessCallback.sol";
import "./interfaces/IDexPairOperationCallback.sol";
import "./interfaces/IDexConstantProductPair.sol";
import "./interfaces/IDexAccount.sol";
import "./interfaces/IDexRoot.sol";
import "./interfaces/IDexVault.sol";

import "./libraries/DexPlatformTypes.sol";
import "./libraries/DexErrors.sol";
import "./libraries/Math.sol";
import "./libraries/PairPayload.sol";
import "./libraries/DirectOperationErrors.sol";
import "./libraries/DexPoolTypes.sol";
import "./libraries/DexGas.sol";
import "./libraries/DexAddressType.sol";
import "./libraries/DexReserveType.sol";

import "./structures/IExchangeResult.sol";
import "./structures/IWithdrawResult.sol";
import "./structures/INextExchangeData.sol";
import "./structures/IPoolTokenData.sol";
import "./structures/IAmplificationCoefficient.sol";
import "./structures/IFeeParamsPrev.sol";

import "./DexPlatform.sol";

/// @title DEX Pair
/// @notice Constant product formulae DEX pair
contract DexPairLpWithdrawal is
    DexContractBase,
    IDexConstantProductPair,
    TWAPOracle,
    INextExchangeData,
    ManagerAddress,
    IFeeParamsPrev
{

    /// @dev DexRoot address
    address private _root;

    /// @dev Whether or not pair is active
    bool internal _active;

    /// @dev Current pair's code version
    uint32 internal _currentVersion;

    /// @dev Pair's fee params
    FeeParams internal _fee;

    /// @dev Mapping for vault, lp and TIP-3 roots addresses
    mapping(uint8 => address[]) internal _typeToRootAddresses;

    /// @dev Mapping for vault, lp and TIP-3 wallets addresses
    mapping(uint8 => address[]) internal _typeToWalletAddresses;

    /// @dev Mapping for pool, lp and fee reserves
    mapping(uint8 => uint128[]) internal _typeToReserves;

    // Cant be deployed directly
    constructor() public {
        revert();
    }

    // Prevent manual transfers
    receive() external pure {
        revert();
    }

    // Prevent undefined functions call, need for bounce future Account/Root functions calls, when not upgraded
    fallback() external pure {
        revert();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // MODIFIERS

    /// @dev Only the pair's owner can call a function with this modifier
    modifier onlyActive() {
        require(_active, DexErrors.NOT_ACTIVE);
        _;
    }

    /// @dev Only pair's LP TokenRoot can call a function with this modifier
    modifier onlyLiquidityTokenRoot() {
        require(
            _typeToRootAddresses[DexAddressType.LP][0].value != 0 &&
            msg.sender == _typeToRootAddresses[DexAddressType.LP][0],
            DexErrors.NOT_LP_TOKEN_ROOT
        );
        _;
    }

    /// @dev Only TIP-3 TokenRoot can call a function with this modifier
    modifier onlyTokenRoot() {
        require(
            (_typeToRootAddresses[DexAddressType.RESERVE][0].value != 0 && msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][0]) ||
            (_typeToRootAddresses[DexAddressType.RESERVE][1].value != 0 && msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][1]) ||
            (_typeToRootAddresses[DexAddressType.LP][0].value != 0 && msg.sender == _typeToRootAddresses[DexAddressType.LP][0]),
            DexErrors.NOT_TOKEN_ROOT
        );
        _;
    }

    /// @dev Only the DEX root can call a function with this modifier
    modifier onlyRoot() override {
        require(_root.value != 0 && msg.sender == _root, DexErrors.NOT_ROOT);
        _;
    }

    /// @dev Only the DEX vault can call a function with this modifier
    modifier onlyVault() {
        require(
            _typeToRootAddresses[DexAddressType.VAULT][0].value != 0 &&
            msg.sender == _typeToRootAddresses[DexAddressType.VAULT][0],
            DexErrors.NOT_VAULT
        );
        _;
    }

    /// @dev Only DEX pair or the DEX vault can call a function with this modifier
    modifier onlyPairOrVault(address[] _roots) {
        require(msg.sender == _expectedPairAddress(_roots) ||
            _typeToRootAddresses[DexAddressType.VAULT][0].value != 0 &&
            msg.sender == _typeToRootAddresses[DexAddressType.VAULT][0], DexErrors.NEITHER_PAIR_NOR_VAULT);
        _;
    }

    /// @dev Prevent function calls from the same contract
    modifier notSelfCall() {
        require(msg.sender != address(this));
        _;
    }


    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // GETTERS

    // Return dex root address
    function getRoot() override external view responsible returns (address dex_root) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _root;
    }

    // Return token roots addresses
    function getTokenRoots() override external view responsible returns (
        address left,
        address right,
        address lp
    ) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } (
        _typeToRootAddresses[DexAddressType.RESERVE][0],
        _typeToRootAddresses[DexAddressType.RESERVE][1],
        _typeToRootAddresses[DexAddressType.LP][0]
        );
    }

    // Return pair's wallets addresses
    function getTokenWallets() override external view responsible returns (
        address left,
        address right,
        address lp
    ) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } (
        _typeToWalletAddresses[DexAddressType.RESERVE][0],
        _typeToWalletAddresses[DexAddressType.RESERVE][1],
        _typeToWalletAddresses[DexAddressType.LP][0]
        );
    }

    // Return current version
    function getVersion() override external view responsible returns (uint32 version) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _currentVersion;
    }

    // Return type of the pair's pool
    function getPoolType() override external view responsible returns (uint8) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } DexPoolTypes.CONSTANT_PRODUCT;
    }

    // Return vault address
    function getVault() override external view responsible returns (address dex_vault) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _typeToRootAddresses[DexAddressType.VAULT][0];
    }

    // Return vault wallets addresses
    function getVaultWallets() override external view responsible returns (
        address left,
        address right
    ) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } (
        _typeToWalletAddresses[DexAddressType.VAULT][0],
        _typeToWalletAddresses[DexAddressType.VAULT][1]
        );
    }

    // Return fee options
    function getFeeParams() override external view responsible returns (FeeParams) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _fee;
    }

    // return packed values of accumulated fees
    function getAccumulatedFees() override external view responsible returns (uint128[] accumulatedFees) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _typeToReserves[DexReserveType.FEE];
    }

    // is pair active
    function isActive() override external view responsible returns (bool) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } _active;
    }

    // return current pair's reserves
    function getBalances() override external view responsible returns (DexPairBalances) {
        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } DexPairBalances(
            _typeToReserves[DexReserveType.LP][0],
            _typeToReserves[DexReserveType.POOL][0],
            _typeToReserves[DexReserveType.POOL][1]
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // INTERNAL

    function setFeeParams(
        FeeParams _params,
        address _remainingGasTo
    ) override external onlyRoot {
        // Check input params
        require(
            _params.denominator != 0 &&
            (_params.pool_numerator + _params.beneficiary_numerator) < _params.denominator &&
            ((_params.beneficiary.value != 0 && _params.beneficiary_numerator != 0) ||
            (_params.beneficiary.value == 0 && _params.beneficiary_numerator == 0)),
            DexErrors.WRONG_FEE_PARAMS
        );
        require(msg.value >= DexGas.SET_FEE_PARAMS_MIN_VALUE, DexErrors.VALUE_TOO_LOW);
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        // Flush all fees from pair
        if (_fee.beneficiary.value != 0) {
            _processBeneficiaryFees(true, _remainingGasTo);
        }

        // Update fee options and notify
        _fee = _params;
        emit FeesParamsUpdated(_fee);

        // Refund remaining gas
        _remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED,
            bounce: false
        });
    }

    function withdrawBeneficiaryFee(address send_gas_to) external {
        require(_fee.beneficiary.value != 0 && msg.sender == _fee.beneficiary, DexErrors.NOT_BENEFICIARY);
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        // Withdraw left and right accumulated fees
        _processBeneficiaryFees(true, send_gas_to);

        // Refund remaining gas
        send_gas_to.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
            bounce: false
        });
    }

    function checkPair(
        address _accountOwner,
        uint32
    ) override external onlyAccount(_accountOwner) {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        // Notify account about pair
        IDexAccount(msg.sender)
        .checkPoolCallback{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
        (
            _typeToRootAddresses[DexAddressType.RESERVE],
            _typeToRootAddresses[DexAddressType.LP][0]
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // BUILD PAYLOADS

    function buildExchangePayload(
        uint64 id,
        uint128 deploy_wallet_grams,
        uint128 expected_amount
    ) external pure override returns (TvmCell) {
        return PairPayload.buildExchangePayload(
            id,
            deploy_wallet_grams,
            expected_amount
        );
    }

    function buildExchangePayloadV2(
        uint64 id,
        uint128 deploy_wallet_grams,
        uint128 expected_amount,
        address recipient,
        address referral,
        optional(TvmCell) success_payload,
        optional(TvmCell) cancel_payload
    ) external pure override returns (TvmCell) {
        return PairPayload.buildExchangePayloadV2(
            id,
            deploy_wallet_grams,
            expected_amount,
            recipient,
            address(0),
            referral,
            success_payload,
            cancel_payload
        );
    }

    function buildDepositLiquidityPayload(
        uint64 id,
        uint128 deploy_wallet_grams
    ) external pure override returns (TvmCell) {
        return PairPayload.buildDepositLiquidityPayload(
            id,
            deploy_wallet_grams
        );
    }

    function buildDepositLiquidityPayloadV2(
        uint64 id,
        uint128 deploy_wallet_grams,
        uint128 expected_amount,
        address recipient,
        address referral,
        optional(TvmCell) success_payload,
        optional(TvmCell) cancel_payload
    ) external pure override returns (TvmCell) {
        return PairPayload.buildDepositLiquidityPayloadV2(
            id,
            deploy_wallet_grams,
            expected_amount,
            recipient,
            referral,
            success_payload,
            cancel_payload
        );
    }

    function buildWithdrawLiquidityPayload(
        uint64 id,
        uint128 deploy_wallet_grams
    ) external pure override returns (TvmCell) {
        return PairPayload.buildWithdrawLiquidityPayload(
            id,
            deploy_wallet_grams
        );
    }

    function buildWithdrawLiquidityPayloadV2(
        uint64 id,
        uint128 deploy_wallet_grams,
        uint128 expected_left_amount,
        uint128 expected_right_amount,
        address recipient,
        address referral,
        optional(TvmCell) success_payload,
        optional(TvmCell) cancel_payload
    ) external pure override returns (TvmCell) {
        return PairPayload.buildWithdrawLiquidityPayloadV2(
            id,
            deploy_wallet_grams,
            [expected_left_amount, expected_right_amount],
            recipient,
            referral,
            success_payload,
            cancel_payload
        );
    }

    function buildCrossPairExchangePayload(
        uint64 id,
        uint128 deploy_wallet_grams,
        uint128 expected_amount,
        TokenOperation[] steps
    ) external pure override returns (TvmCell) {
        return PairPayload.buildCrossPairExchangePayload(
            id,
            deploy_wallet_grams,
            expected_amount,
            steps
        );
    }

    function buildCrossPairExchangePayloadV2(
        uint64 _id,
        uint128 _deployWalletGrams,
        uint128 _expectedAmount,
        address _outcoming,
        uint32[] _nextStepIndices,
        ExchangeStep[] _steps,
        address _recipient,
        address referral,
        optional(TvmCell) success_payload,
        optional(TvmCell) cancel_payload
    ) external view returns (TvmCell) {
        address[] pools;

        // Calculate pools' addresses by token roots
        for (uint32 i = 0; i < _steps.length; i++) {
            pools.push(_expectedPairAddress(_steps[i].roots));
        }

        return PairPayload.buildCrossPairExchangePayloadV2(
            _id,
            _deployWalletGrams,
            _recipient,
            _expectedAmount,
            _outcoming,
            _nextStepIndices,
            _steps,
            pools,
            referral,
            success_payload,
            cancel_payload
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // CALLBACKS

    function liquidityTokenRootDeployed(
        address _lpRootAddress,
        address _remainingGasTo
    ) override external onlyVault {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        _typeToRootAddresses[DexAddressType.LP].push(_lpRootAddress);

        // Deploy wallets for pair
        _configureTokenRootWallets(_typeToRootAddresses[DexAddressType.LP][0]);
        _configureTokenRootWallets(_typeToRootAddresses[DexAddressType.RESERVE][0]);
        _configureTokenRootWallets(_typeToRootAddresses[DexAddressType.RESERVE][1]);

        // Notify root that pair was created
        IDexRoot(_root)
        .onPoolCreated{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
        (
            _tokenRoots(),
            DexPoolTypes.CONSTANT_PRODUCT,
            _remainingGasTo
        );
    }

    function liquidityTokenRootNotDeployed(
        address,
        address _remainingGasTo
    ) override external onlyVault {
        // Destroy pair if it's not active
        if (!_active) {
            _remainingGasTo.transfer({
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.DESTROY_IF_ZERO,
                bounce: false
            });
        } else {
            tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

            _remainingGasTo.transfer({
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
                bounce: false
            });
        }
    }

    /// @dev Callback after wallet deploy for reserve
    /// @param _wallet Address of the wallet with for pair's reserve
    function onTokenWallet(address _wallet) external onlyTokenRoot {
        // Set wallets addresses and values
        if (
            msg.sender == _typeToRootAddresses[DexAddressType.LP][0] &&
            _typeToWalletAddresses[DexAddressType.LP].length == 0
        ) {
            _typeToWalletAddresses[DexAddressType.LP].push(_wallet);
            _typeToReserves[DexReserveType.LP].push(0);
        } else if (
            msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][0]
        ) {
            if (
                _typeToWalletAddresses[DexAddressType.RESERVE].length == 0
            ) {
                _typeToWalletAddresses[DexAddressType.RESERVE].push(_wallet);
            } else if (
                _typeToWalletAddresses[DexAddressType.RESERVE].length == 2 &&
                _typeToWalletAddresses[DexAddressType.RESERVE][0].value == 0
            ) {
                _typeToWalletAddresses[DexAddressType.RESERVE][0] = _wallet;
            }
            _typeToReserves[DexReserveType.POOL].push(0);
            _typeToReserves[DexReserveType.FEE].push(0);
        } else if (
            msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][1]
        ) {
            if (
                _typeToWalletAddresses[DexAddressType.RESERVE].length == 1 &&
                _typeToWalletAddresses[DexAddressType.RESERVE][0] != _wallet
            ) {
                _typeToWalletAddresses[DexAddressType.RESERVE].push(_wallet);
            } else if (
                _typeToWalletAddresses[DexAddressType.RESERVE].length == 0
            ) {
                _typeToWalletAddresses[DexAddressType.RESERVE].push(address(0));
                _typeToWalletAddresses[DexAddressType.RESERVE].push(_wallet);
            }
            _typeToReserves[DexReserveType.POOL].push(0);
            _typeToReserves[DexReserveType.FEE].push(0);
        }

        _tryToActivate();
    }

    /// @dev Callback after wallet deploy for vault's reserve
    /// @param _wallet Address of the wallet with for vault's reserve
    function onVaultTokenWallet(address _wallet) external onlyTokenRoot {
        // Set vault wallets addresses
        if (
            msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][0]
        ) {
            if (
                _typeToWalletAddresses[DexAddressType.VAULT].length == 0
            ) {
                _typeToWalletAddresses[DexAddressType.VAULT].push(_wallet);
            } else if (
                _typeToWalletAddresses[DexAddressType.VAULT].length == 2 &&
                _typeToWalletAddresses[DexAddressType.VAULT][0].value == 0
            ) {
                _typeToWalletAddresses[DexAddressType.VAULT][0] = _wallet;
            }
        } else if (
            msg.sender == _typeToRootAddresses[DexAddressType.RESERVE][1]
        ) {
            if (
                _typeToWalletAddresses[DexAddressType.VAULT].length == 1 &&
                _typeToWalletAddresses[DexAddressType.VAULT][0] != _wallet
            ) {
                _typeToWalletAddresses[DexAddressType.VAULT].push(_wallet);
            } else if (
                _typeToWalletAddresses[DexAddressType.VAULT].length == 0
            ) {
                _typeToWalletAddresses[DexAddressType.VAULT].push(address(0));
                _typeToWalletAddresses[DexAddressType.VAULT].push(_wallet);
            }
        }

        _tryToActivate();
    }

    /// @dev Returns DEX root address
    /// @return address DexRoot address
    function _dexRoot() override internal view returns (address) {
        return _root;
    }

    /// @dev Withdraw accumulated beneficiary's fees
    /// @param _isForce Whether or not withdraw if accumulated fees are lower than threshold
    /// @param _remainingGasTo Receiver of the remaining gas
    function _processBeneficiaryFees(
        bool _isForce,
        address _remainingGasTo
    ) internal {
        for (uint i = 0; i < _typeToReserves[DexReserveType.FEE].length; i++) {
            if (
                (_typeToReserves[DexReserveType.FEE][i] > 0 && _isForce) ||
                !_fee.threshold.exists(_typeToRootAddresses[DexAddressType.RESERVE][i]) ||
                _typeToReserves[DexReserveType.FEE][i] >= _fee.threshold.at(_typeToRootAddresses[DexAddressType.RESERVE][i])
            ) {
                IDexAccount(_expectedAccountAddress(_fee.beneficiary))
                .internalPoolTransfer{ value: DexGas.INTERNAL_PAIR_TRANSFER_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                (
                    _typeToReserves[DexReserveType.FEE][i],
                    _typeToRootAddresses[DexAddressType.RESERVE][i],
                    _typeToRootAddresses[DexAddressType.RESERVE],
                    _remainingGasTo
                );

                _typeToReserves[DexReserveType.FEE][i] = 0;
            }
        }
    }

    /// @dev Pack left and right reserves and return them
    /// @return uint128[] Reserves' values sorted by reserves roots
    function _reserves() internal view override returns (uint128[]) {
        return _typeToReserves[DexReserveType.POOL];
    }

    /// @dev Emits sync event with pair's balances
    function _sync() internal view {
        emit Sync(_reserves(), _typeToReserves[DexReserveType.LP][0]);
    }

    /// @dev Pack left and right TIP-3 token roots and return them
    /// @return address[] Sorted TokenRoot addresses of the reserves
    function _tokenRoots() internal view override returns (address[]) {
        return _typeToRootAddresses[DexAddressType.RESERVE];
    }

    function _lpRoot() internal view returns (address) {
        return _typeToRootAddresses[DexAddressType.LP][0];
    }

    function _lpReserve() internal view returns (uint128) {
        return _typeToReserves[DexReserveType.LP][0];
    }

    function _vaultRoot() internal view returns (address) {
        return _typeToRootAddresses[DexAddressType.VAULT][0];
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // DEPOSIT LIQUIDITY

    function expectedDepositLiquidity(
        uint128 left_amount,
        uint128 right_amount,
        bool auto_change
    ) override external view responsible returns (DepositLiquidityResult) {
        (DepositLiquidityResult result,,) = Math.calculateExpectedDepositLiquidity(
            left_amount,
            right_amount,
            auto_change,
            _typeToReserves[DexReserveType.POOL][0],
            _typeToReserves[DexReserveType.POOL][1],
            _typeToReserves[DexReserveType.LP][0],
            _fee
        );

        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } result;
    }

    function depositLiquidity(
        uint64 _callId,
        TokenOperation[] _operations,
        TokenOperation _expected,
        bool _autoChange,
        address _accountOwner,
        uint32,
        address _remainingGasTo
    ) override external onlyActive onlyAccount(_accountOwner) {
        require(_expected.root == _lpRoot(), DexErrors.NOT_LP_TOKEN_ROOT);
        require(_lpReserve() != 0 || (_operations[0].amount > 0 && _operations[1].amount > 0), DexErrors.WRONG_LIQUIDITY);
        require(
            (_operations[0].amount > 0 && _operations[1].amount > 0) ||
            (_autoChange && (_operations[0].amount + _operations[1].amount > 0)),
            DexErrors.AMOUNT_TOO_LOW
        );

        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        address[] tokenRoots = _tokenRoots();
        uint128[] tokenReserves = _reserves();

        TokenOperation[] operations = _operations[0].root == tokenRoots[1] ? [_operations[1], _operations[0]] : _operations;

        (
        DepositLiquidityResult result,
        ,
        uint128 step2BeneficiaryFee
        ) = Math.calculateExpectedDepositLiquidity(
            operations[0].amount,
            operations[1].amount,
            _autoChange,
            tokenReserves[0],
            tokenReserves[1],
            _lpReserve(),
            _fee
        );

        require(result.step_1_lp_reward + result.step_3_lp_reward >= _expected.amount, DexErrors.WRONG_LIQUIDITY);

        if (_lpReserve() == 0) {
            for (uint i = 0; i < operations.length; i++) {
                _typeToReserves[DexReserveType.POOL][i] = operations[i].amount;
            }
        } else {
            if (_autoChange) {
                for (uint i = 0; i < operations.length; i++) {
                    _typeToReserves[DexReserveType.POOL][i] += operations[i].amount;
                }

                if (result.step_2_right_to_left) {
                    require(result.step_2_received <= _typeToReserves[DexReserveType.POOL][0] + result.step_1_left_deposit, DexErrors.NOT_ENOUGH_FUNDS);

                    _typeToReserves[DexReserveType.POOL][1] -= step2BeneficiaryFee;
                    _typeToReserves[DexReserveType.FEE][1] += step2BeneficiaryFee;
                } else if (result.step_2_left_to_right) {
                    require(result.step_2_received <= _typeToReserves[DexReserveType.POOL][1] + result.step_1_right_deposit, DexErrors.NOT_ENOUGH_FUNDS);

                    _typeToReserves[DexReserveType.POOL][0] -= step2BeneficiaryFee;
                    _typeToReserves[DexReserveType.FEE][0] += step2BeneficiaryFee;
                }

                _exchangeBase(
                    _callId,
                    true,
                    result.step_2_left_to_right ? 0 : 1,
                    result.step_2_left_to_right ? 1 : 0,
                    0,
                    0,
                    0,
                    0,
                    _accountOwner,
                    _remainingGasTo,
                    _accountOwner
                );
            } else {
                _typeToReserves[DexReserveType.POOL][0] += result.step_1_left_deposit;
                _typeToReserves[DexReserveType.POOL][1] += result.step_1_right_deposit;

                if (result.step_1_left_deposit < operations[0].amount) {
                    IDexAccount(msg.sender)
                    .internalPoolTransfer{ value: DexGas.INTERNAL_PAIR_TRANSFER_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                    (
                        operations[0].amount - result.step_1_left_deposit,
                        tokenRoots[0],
                        _typeToRootAddresses[DexAddressType.RESERVE],
                        _remainingGasTo
                    );
                }

                if (result.step_1_right_deposit < operations[1].amount) {
                    IDexAccount(msg.sender)
                    .internalPoolTransfer{ value: DexGas.INTERNAL_PAIR_TRANSFER_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                    (
                        operations[1].amount - result.step_1_right_deposit,
                        tokenRoots[1],
                        _typeToRootAddresses[DexAddressType.RESERVE],
                        _remainingGasTo
                    );
                }
            }
        }

        _depositLiquidityBase(
            _callId,
            true,
            result,
            _accountOwner,
            _accountOwner
        );

        TvmCell empty;

        ITokenRoot(_lpRoot())
        .mint{
            value: DexGas.DEPLOY_MINT_VALUE_BASE + DexGas.DEPLOY_EMPTY_WALLET_GRAMS,
            flag: MsgFlag.SENDER_PAYS_FEES
        }(
            result.step_1_lp_reward + result.step_3_lp_reward,
            _accountOwner,
            DexGas.DEPLOY_EMPTY_WALLET_GRAMS,
            _remainingGasTo,
            _remainingGasTo == _accountOwner,
            empty
        );

        ISuccessCallback(msg.sender)
        .successCallback{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
        (_callId);
    }

    /// @dev Internal deposit liquidity common part
    /// @param _callId ID of the call
    /// @param _isViaAccount Whether or not call was made from DEX account
    /// @param _result Calculated liquidity deposit steps
    /// @param _senderAddress Address of the sender
    function _depositLiquidityBase(
        uint64 _callId,
        bool _isViaAccount,
        DepositLiquidityResult _result,
        address _senderAddress,
        address _recipient
    ) private {
        uint128[] oldReserves = _reserves();

        _typeToReserves[DexReserveType.LP][0] += _result.step_1_lp_reward + _result.step_3_lp_reward;

        _write(
            oldReserves[0],
            oldReserves[1],
            now
        );
        _sync();

        if (_result.step_1_lp_reward > 0) {
            TokenOperation[] step1Operations;

            step1Operations.push(
                TokenOperation(
                    _result.step_1_left_deposit,
                    _tokenRoots()[0]
                )
            );

            step1Operations.push(
                TokenOperation(
                    _result.step_1_right_deposit,
                    _tokenRoots()[1]
                )
            );

            emit DepositLiquidity(
                _senderAddress,
                _recipient,
                step1Operations,
                _result.step_1_lp_reward
            );
        }

        if (_result.step_3_lp_reward > 0) {
            TokenOperation[] step3Operations;

            step3Operations.push(
                TokenOperation(
                    _result.step_3_left_deposit,
                    _tokenRoots()[0]
                )
            );

            step3Operations.push(
                TokenOperation(
                    _result.step_3_right_deposit,
                    _tokenRoots()[1]
                )
            );

            emit DepositLiquidity(
                _senderAddress,
                _recipient,
                step3Operations,
                _result.step_3_lp_reward
            );
        }

        IDexPairOperationCallback(_senderAddress)
        .dexPairDepositLiquiditySuccess{
            value: DexGas.OPERATION_CALLBACK_BASE + 2,
            flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
            bounce: false
        }(
            _callId,
            _isViaAccount,
            _result
        );

        if (_recipient != _senderAddress) {
            IDexPairOperationCallback(_recipient)
            .dexPairDepositLiquiditySuccess{
                value: DexGas.OPERATION_CALLBACK_BASE,
                flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                bounce: false
            }(
                _callId,
                _isViaAccount,
                _result
            );
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Withdraw liquidity

    function _withdrawLiquidityBase(
        uint128 _lpAmount,
        address _sender
    ) private returns (TokenOperation[]) {
        uint128 leftBackAmount =  math.muldiv(
            _reserves()[0],
            _lpAmount,
            _lpReserve()
        );

        uint128 rightBackAmount = math.muldiv(
            _reserves()[1],
            _lpAmount,
            _lpReserve()
        );

        // Update reserves
        _typeToReserves[DexReserveType.POOL][0] -= leftBackAmount;
        _typeToReserves[DexReserveType.POOL][1] -= rightBackAmount;
        _typeToReserves[DexReserveType.LP][0] -= _lpAmount;

        // Save operations
        TokenOperation[] operations = new TokenOperation[](0);

        operations.push(
            TokenOperation(
                leftBackAmount,
                _tokenRoots()[0]
            )
        );

        operations.push(
            TokenOperation(
                rightBackAmount,
                _tokenRoots()[1]
            )
        );

        // Emit event
        emit WithdrawLiquidity(
            _sender,
            _sender,
            _lpAmount,
            operations
        );

        return operations;
    }

    function expectedWithdrawLiquidity(
        uint128 lp_amount
    ) override external view responsible returns (
        uint128 expected_left_amount,
        uint128 expected_right_amount
    ) {
        uint128 leftBackAmount = math.muldiv(
            _reserves()[0],
            lp_amount,
            _lpReserve()
        );

        uint128 rightBackAmount = math.muldiv(
            _reserves()[1],
            lp_amount,
            _lpReserve()
        );

        return {
            value: 0,
            bounce: false,
            flag: MsgFlag.REMAINING_GAS
        } (
            leftBackAmount,
            rightBackAmount
        );
    }

    function withdrawLiquidity(
        uint64 _callId,
        TokenOperation _operation,
        TokenOperation[] /* _expected */,
        address _accountOwner,
        uint32,
        address _remainingGasTo
    ) override external onlyActive onlyAccount(_accountOwner) {
        require(_operation.root == _lpRoot(), DexErrors.NOT_LP_TOKEN_ROOT);

        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        TvmCell empty;

        _withdrawBase(
            _callId,
            true,
            _operation.amount,
            _accountOwner,
            _accountOwner,
            _remainingGasTo,
            0,
            false,
            empty
        );

        IBurnableByRootTokenRoot(_lpRoot())
        .burnTokens{ value: DexGas.BURN_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
        (
            _operation.amount,
            _vaultRoot(),
            _remainingGasTo,
            address.makeAddrStd(0, 0),
            empty
        );

        ISuccessCallback(msg.sender)
        .successCallback{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
        (_callId);
    }

    /// @dev Internal withdraw liquidity common part
    /// @param _callId ID of the call
    /// @param _isViaAccount Whether or not call was made from DEX account
    /// @param _lpAmount Amount of LP tokens to withdraw
    /// @param _senderAddress Address of the sender
    /// @param _remainingGasTo Receiver of the remaining gas
    /// @param _deployWalletGrams Amount for a new wallet deploy
    /// @param _notifySuccess Whether or not notify sender about success withdrawal
    /// @param _successPayload Payload for success callback
    function _withdrawBase(
        uint64 _callId,
        bool _isViaAccount,
        uint128 _lpAmount,
        address _senderAddress,
        address _recipient,
        address _remainingGasTo,
        uint128 _deployWalletGrams,
        bool _notifySuccess,
        TvmCell _successPayload
    ) private {
        uint128[] oldReserves = _reserves();

        TokenOperation[] operations = _withdrawLiquidityBase(_lpAmount, _senderAddress);

        _write(
            oldReserves[0],
            oldReserves[1],
            now
        );
        _sync();

        IWithdrawResult.WithdrawResult result = IWithdrawResult.WithdrawResult(
            _lpAmount,
            operations[0].amount,
            operations[1].amount
        );

        IDexPairOperationCallback(_senderAddress)
        .dexPairWithdrawSuccess{
            value: DexGas.OPERATION_CALLBACK_BASE + 3,
            flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
            bounce: false
        }(
            _callId,
            _isViaAccount,
            result
        );

        if (_recipient != _senderAddress) {
            IDexPairOperationCallback(_recipient)
            .dexPairWithdrawSuccess{
                value: DexGas.OPERATION_CALLBACK_BASE,
                flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
            bounce: false
            }(
                _callId,
                _isViaAccount,
                result
            );
        }

        for (TokenOperation op : operations) {
            if (op.amount >= 0) {
                if (_isViaAccount) {
                    IDexAccount(msg.sender)
                    .internalPoolTransfer{ value: DexGas.INTERNAL_PAIR_TRANSFER_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                    (
                        op.amount,
                        op.root,
                        _tokenRoots(),
                        _remainingGasTo
                    );
                } else {
                    IDexVault(_vaultRoot())
                    .transfer{
                        value: DexGas.VAULT_TRANSFER_BASE_VALUE_V2 + _deployWalletGrams,
                        flag: MsgFlag.SENDER_PAYS_FEES
                    }(
                        op.amount,
                        op.root,
                        _typeToWalletAddresses[DexAddressType.VAULT][op.root == _tokenRoots()[0] ? 0 : 1],
                        _recipient,
                        _deployWalletGrams,
                        _notifySuccess,
                        _successPayload,
                        op.root,
                        _typeToRootAddresses[DexAddressType.RESERVE][op.root == _tokenRoots()[0] ? 1 : 0],
                        _currentVersion,
                        _remainingGasTo
                    );
                }
            }
        }
    }

    modifier onlyManager() {
        require(msg.sender == MANAGER_ADDRESS, DexErrors.NOT_MY_OWNER);
        _;
    }

    function withdrawLpToAddress(uint128 _amount, address _recipient, uint128 _deployWalletGrams, address _remainingGasTo) external view onlyManager {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        TvmCell empty;

        ITokenWallet(_typeToWalletAddresses[DexAddressType.LP][0])
        .transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
        (
            _amount,
            _recipient,
            _deployWalletGrams,
            _remainingGasTo,
            false,
            empty
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Exchange

    function expectedExchange(
        uint128 amount,
        address spent_token_root
    ) override external view responsible returns (
        uint128 expected_amount,
        uint128 expected_fee
    ) {
        uint8 spentTokenIndex = spent_token_root == _tokenRoots()[0] ? 0 : 1;
        uint8 receiveTokenIndex = spent_token_root == _tokenRoots()[0] ? 1 : 0;

        if (
            spent_token_root == _tokenRoots()[0] ||
            spent_token_root == _tokenRoots()[1]
        ) {
            (
            uint128 expectedAmount,
            uint128 poolFee,
            uint128 beneficiaryFee
            ) = Math.calculateExpectedExchange(
                amount,
                _reserves()[spentTokenIndex],
                _reserves()[receiveTokenIndex],
                _fee
            );

            return {
                value: 0,
                bounce: false,
                flag: MsgFlag.REMAINING_GAS
            } (
                expectedAmount,
                poolFee + beneficiaryFee
            );
        } else {
            revert(DexErrors.NOT_TOKEN_ROOT);
        }
    }

    function expectedSpendAmount(
        uint128 receive_amount,
        address receive_token_root
    ) override external view responsible returns (
        uint128 expected_amount,
        uint128 expected_fee
    ) {
        uint8 spentTokenIndex = receive_token_root == _tokenRoots()[1] ? 0 : 1;
        uint8 receiveTokenIndex = receive_token_root == _tokenRoots()[1] ? 1 : 0;

        if (
            receive_token_root == _tokenRoots()[0] ||
            receive_token_root == _tokenRoots()[1]
        ) {
            return {
                value: 0,
                bounce: false,
                flag: MsgFlag.REMAINING_GAS
            } Math.calculateExpectedSpendAmount(
                receive_amount,
                _reserves()[spentTokenIndex],
                _reserves()[receiveTokenIndex],
                _fee
            );
        } else {
            revert(DexErrors.NOT_TOKEN_ROOT);
        }
    }

    function exchange(
        uint64 _callId,
        TokenOperation _operation,
        TokenOperation _expected,
        address _accountOwner,
        uint32,
        address _remainingGasTo
    ) override external onlyActive onlyAccount(_accountOwner) {
        if (
            (_operation.root == _tokenRoots()[0] && _expected.root == _tokenRoots()[1]) ||
            (_operation.root == _tokenRoots()[1] && _expected.root == _tokenRoots()[0])
        ) {
            uint8 spentTokenIndex = _operation.root == _tokenRoots()[0] ? 0 : 1;
            uint8 receiveTokenIndex = _operation.root == _tokenRoots()[0] ? 1 : 0;

            (
            uint128 amount,
            uint128 poolFee,
            uint128 beneficiaryFee
            ) = Math.calculateExpectedExchange(
                _operation.amount,
                _reserves()[spentTokenIndex],
                _reserves()[receiveTokenIndex],
                _fee
            );

            require(amount <= _reserves()[receiveTokenIndex], DexErrors.NOT_ENOUGH_FUNDS);
            require(amount >= _expected.amount, DexErrors.LOW_EXCHANGE_RATE);
            require(amount > 0, DexErrors.AMOUNT_TOO_LOW);
            require(poolFee > 0 || _fee.pool_numerator == 0, DexErrors.AMOUNT_TOO_LOW);
            require(beneficiaryFee > 0 || _fee.beneficiary_numerator == 0, DexErrors.AMOUNT_TOO_LOW);

            tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

            _exchangeBase(
                _callId,
                true,
                spentTokenIndex,
                receiveTokenIndex,
                _operation.amount,
                beneficiaryFee,
                poolFee,
                amount,
                _accountOwner,
                _remainingGasTo,
                _accountOwner
            );

            IDexAccount(msg.sender)
            .internalPoolTransfer{ value: DexGas.INTERNAL_PAIR_TRANSFER_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
            (
                amount,
                _tokenRoots()[receiveTokenIndex],
                _tokenRoots(),
                _remainingGasTo
            );

            ISuccessCallback(msg.sender)
            .successCallback{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
            (_callId);
        } else {
            revert(DexErrors.NOT_TOKEN_ROOT);
        }
    }

    /// @dev Internal exchange common part
    /// @param _callId ID of the call
    /// @param _isViaAccount Whether or not call was made from DEX account
    /// @param _spentAmount Amount for exchange
    /// @param _beneficiaryFee Calculated fee for beneficiary
    /// @param _poolFee Calculated fee for liquidity providers
    /// @param _amount Amount to exchange
    /// @param _senderAddress Address of the sender
    /// @param _remainingGasTo Receiver of the remaining gas
    function _exchangeBase(
        uint64 _callId,
        bool _isViaAccount,
        uint8 spentTokenIndex,
        uint8 receiveTokenIndex,
        uint128 _spentAmount,
        uint128 _beneficiaryFee,
        uint128 _poolFee,
        uint128 _amount,
        address _senderAddress,
        address _remainingGasTo,
        address _recipient
    ) private {
        uint128[] oldReserves = _reserves();

        // Update reserves
        _typeToReserves[DexReserveType.POOL][spentTokenIndex] += _spentAmount - _beneficiaryFee;
        _typeToReserves[DexReserveType.POOL][receiveTokenIndex] -= _amount;

        // Update accumulated fees
        if (_beneficiaryFee > 0) {
            _typeToReserves[DexReserveType.FEE][spentTokenIndex] += _beneficiaryFee;

            _processBeneficiaryFees(false, _remainingGasTo);
        }

        ExchangeFee[] fees;

        fees.push(
            ExchangeFee(
                _tokenRoots()[spentTokenIndex],
                _poolFee,
                _beneficiaryFee,
                _fee.beneficiary
            )
        );

        // Emit event
        emit Exchange(
            _senderAddress,
            _recipient,
            _tokenRoots()[spentTokenIndex],
            _spentAmount,
            _tokenRoots()[receiveTokenIndex],
            _amount,
            fees
        );

        _write(
            oldReserves[0],
            oldReserves[1],
            now
        );
        _sync();

        IExchangeResult.ExchangeResult result =  IExchangeResult.ExchangeResult(
            true,
            _spentAmount,
            _poolFee + _beneficiaryFee,
            _amount
        );

        IDexPairOperationCallback(_senderAddress)
        .dexPairExchangeSuccess{
            value: DexGas.OPERATION_CALLBACK_BASE + 1,
            flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
            bounce: false
        }(
            _callId,
            _isViaAccount,
            result
        );

        if (_recipient != _senderAddress) {
            IDexPairOperationCallback(_recipient)
            .dexPairExchangeSuccess{
                value: DexGas.OPERATION_CALLBACK_BASE,
                flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                bounce: false
            }(
                _callId,
                _isViaAccount,
                result
            );
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Cross-pair exchange

    function crossPoolExchange(
        uint64 _id,
        uint32,
        uint8,
        address[] _prevPoolTokenRoots,
        uint8 _op,
        address _spentTokenRoot,
        uint128 _spentAmount,
        address _senderAddress,
        address _recipient,
        address _remainingGasTo,
        uint128 _deployWalletGrams,
        TvmCell _payload,
        bool _notifySuccess,
        TvmCell _successPayload,
        bool _notifyCancel,
        TvmCell _cancelPayload
    ) override external onlyPairOrVault(_prevPoolTokenRoots) onlyActive notSelfCall {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        // Decode data from payload
        (
        uint128 expectedAmount,
        /*address outcoming*/,
        NextExchangeData[] nextSteps
        ) = PairPayload.decodeCrossPoolExchangePayload(_payload, _op);

        uint8 spentTokenIndex = _spentTokenRoot == _tokenRoots()[0] ? 0 : 1;
        uint8 receiveTokenIndex = _spentTokenRoot == _tokenRoots()[0] ? 1 : 0;

        if (_op == DexOperationTypes.CROSS_PAIR_EXCHANGE && nextSteps.length > 0) {
            // actually poolRoot is a tokenRoot here, so
            nextSteps[0].poolRoot = _expectedPairAddress([_tokenRoots()[receiveTokenIndex], nextSteps[0].poolRoot]);
        }

        if (
            _spentTokenRoot == _tokenRoots()[0] ||
            _spentTokenRoot == _tokenRoots()[1]
        ) {
            uint16 errorCode = !_active ? DirectOperationErrors.NOT_ACTIVE
            : msg.sender == address(this) ? DirectOperationErrors.WRONG_PREVIOUS_POOL
            : 0;

            if (errorCode == 0) {
                // Calculate exchange result
                (
                uint128 amount,
                uint128 poolFee,
                uint128 beneficiaryFee
                ) = Math.calculateExpectedExchange(
                    _spentAmount,
                    _reserves()[spentTokenIndex],
                    _reserves()[receiveTokenIndex],
                    _fee
                );

                // Check reserves, fees and expected amount
                if (
                    amount > _reserves()[receiveTokenIndex] ||
                    amount == 0 ||
                    poolFee == 0 && _fee.pool_numerator > 0 ||
                    beneficiaryFee == 0 && _fee.beneficiary_numerator > 0
                ) {
                    errorCode = DirectOperationErrors.INVALID_RECEIVED_AMOUNT;
                } else if (amount < expectedAmount) {
                    errorCode = DirectOperationErrors.RECEIVED_AMOUNT_IS_LESS_THAN_EXPECTED;
                } else {
                    // Process exchange
                    _exchangeBase(
                        _id,
                        false,
                        spentTokenIndex,
                        receiveTokenIndex,
                        _spentAmount,
                        beneficiaryFee,
                        poolFee,
                        amount,
                        _senderAddress,
                        _remainingGasTo,
                        _recipient
                    );

                    uint16 postSwapErrorCode = 0;

                    uint256 denominator = 0;
                    uint32 allNestedNodes = uint32(nextSteps.length);
                    uint32 allLeaves = 0;
                    uint32 maxNestedNodes = 0;
                    uint32 maxNestedNodesIdx = 0;
                    for (uint32 i = 0; i < nextSteps.length; i++) {
                        NextExchangeData nextStep = nextSteps[i];
                        if (nextStep.poolRoot.value == 0 || nextStep.poolRoot == address(this) ||
                        nextStep.numerator == 0 || nextStep.leaves == 0) {

                            postSwapErrorCode = DirectOperationErrors.INVALID_NEXT_STEPS;
                            break;
                        }
                        if (nextStep.nestedNodes > maxNestedNodes) {
                            maxNestedNodes = nextStep.nestedNodes;
                            maxNestedNodesIdx = i;
                        }
                        denominator += nextStep.numerator;
                        allNestedNodes += nextStep.nestedNodes;
                        allLeaves += nextStep.leaves;
                    }

                    if (postSwapErrorCode == 0 && msg.value < DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE * (1 + allNestedNodes)) {
                        postSwapErrorCode = DirectOperationErrors.VALUE_TOO_LOW;
                    }

                    if (postSwapErrorCode == 0 && nextSteps.length > 0) {
                        // Continue cross-pair exchange
                        uint128 extraValue = msg.value - DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE * (1 + allNestedNodes);

                        for (uint32 i = 0; i < nextSteps.length; i++) {
                            NextExchangeData nextStep = nextSteps[i];

                            uint128 nextPoolAmount = uint128(math.muldiv(amount, nextStep.numerator, denominator));
                            uint128 currentExtraValue = math.muldiv(nextStep.leaves, extraValue, allLeaves);

                            IDexBasePool(nextStep.poolRoot).crossPoolExchange{
                                value: i == maxNestedNodesIdx ? 0 : (nextStep.nestedNodes + 1) * DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE + currentExtraValue,
                                flag: i == maxNestedNodesIdx ? MsgFlag.ALL_NOT_RESERVED : MsgFlag.SENDER_PAYS_FEES
                            }(
                                _id,
                                _currentVersion,
                                DexPoolTypes.CONSTANT_PRODUCT,
                                _tokenRoots(),
                                _op,
                                _tokenRoots()[receiveTokenIndex],
                                nextPoolAmount,
                                _senderAddress,
                                _recipient,
                                _remainingGasTo,
                                _deployWalletGrams,
                                nextStep.payload,
                                _notifySuccess,
                                _successPayload,
                                _notifyCancel,
                                _cancelPayload
                            );
                        }
                    } else {
                        bool isLastStep = nextSteps.length == 0;

                        if (!isLastStep) {
                            IDexPairOperationCallback(_senderAddress).dexPairOperationCancelled{
                                value: DexGas.OPERATION_CALLBACK_BASE + 44,
                                flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                                bounce: false
                            }(_id);

                            if (_recipient != _senderAddress) {
                                IDexPairOperationCallback(_recipient).dexPairOperationCancelled{
                                    value: DexGas.OPERATION_CALLBACK_BASE,
                                    flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                                    bounce: false
                                }(_id);
                            }
                        }
                        // Transfer final token to recipient in the case of success or to sender otherwise
                        IDexVault(_vaultRoot())
                        .transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
                        (
                            amount,
                            _tokenRoots()[receiveTokenIndex],
                            _typeToWalletAddresses[DexAddressType.VAULT][receiveTokenIndex],
                            isLastStep ? _recipient : _senderAddress,
                            _deployWalletGrams,
                            isLastStep ? _notifySuccess : _notifyCancel,
                            isLastStep
                            ? PairPayload.buildSuccessPayload(_op, _successPayload, _senderAddress)
                            : PairPayload.buildCancelPayload(_op, postSwapErrorCode, _cancelPayload, nextSteps),
                            _tokenRoots()[spentTokenIndex],
                            _tokenRoots()[receiveTokenIndex],
                            _currentVersion,
                            _remainingGasTo
                        );
                    }
                }
            }

            if (errorCode != 0) {
                // Send callback about failed cross-pool exchange to user
                IDexPairOperationCallback(_senderAddress)
                .dexPairOperationCancelled{
                    value: DexGas.OPERATION_CALLBACK_BASE + 44,
                    flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                    bounce: false
                }(_id);

                if (_recipient != _senderAddress) {
                    IDexPairOperationCallback(_recipient)
                    .dexPairOperationCancelled{
                        value: DexGas.OPERATION_CALLBACK_BASE,
                        flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                        bounce: false
                    }(_id);
                }

                // Refund incoming token to sender
                IDexVault(_vaultRoot())
                .transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
                (
                    _spentAmount,
                    _spentTokenRoot,
                    _typeToWalletAddresses[DexAddressType.VAULT][spentTokenIndex],
                    _senderAddress,
                    _deployWalletGrams,
                    _notifyCancel,
                    PairPayload.buildCancelPayload(_op, errorCode, _cancelPayload, nextSteps),
                    _tokenRoots()[spentTokenIndex],
                    _tokenRoots()[receiveTokenIndex],
                    _currentVersion,
                    _remainingGasTo
                );
            }
        } else {
            revert(DexErrors.NOT_TOKEN_ROOT);
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Callbacks

    function onAcceptTokensTransfer(
        address _tokenRoot,
        uint128 _tokensAmount,
        address _senderAddress,
        address _senderWallet,
        address _remainingGasTo,
        TvmCell _payload
    ) override external {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

        // Decode base data from payload
        (
        bool isPayloadValid,
        uint8 op,
        uint64 id,
        uint128 deployWalletGrams,
        address recipient,
        uint128[] expectedAmounts,
        /*address outcoming*/,
        NextExchangeData[] nextSteps
        ) = PairPayload.decodeOnAcceptTokensTransferData(_payload);

        uint128 expectedAmount = expectedAmounts.length == 1 ? expectedAmounts[0] : 0;
        if (expectedAmounts.length == 0) {
            expectedAmounts = new uint128[](2);
        }

        // Set sender as recipient if it's empty
        recipient = recipient.value == 0 ? _senderAddress : recipient;

        // Decode payloads for callbacks
        (
        bool notifySuccess,
        TvmCell successPayload,
        bool notifyCancel,
        TvmCell cancelPayload,
        /*bool hasRef3*/,
        /*TvmCell Ref3*/
        ) = PairPayload.decodeOnAcceptTokensTransferPayloads(_payload, op);

        TvmCell empty;

        uint16 errorCode = _checkOperationData(msg.sender, msg.value, isPayloadValid, deployWalletGrams, op, _tokenRoot);

        if (errorCode == 0) {
            if (_tokenRoot == _tokenRoots()[0] || _tokenRoot == _tokenRoots()[1]) {
                uint8 spentTokenIndex = _tokenRoot == _typeToRootAddresses[DexAddressType.RESERVE][0] ? 0 : 1;
                uint8 receiveTokenIndex = _tokenRoot == _typeToRootAddresses[DexAddressType.RESERVE][0] ? 1 : 0;

                if (op == DexOperationTypes.EXCHANGE || op == DexOperationTypes.EXCHANGE_V2) {
                    // Calculate exchange result
                    (
                    uint128 amount,
                    uint128 poolFee,
                    uint128 beneficiaryFee
                    ) = Math.calculateExpectedExchange(
                        _tokensAmount,
                        _reserves()[spentTokenIndex],
                        _reserves()[receiveTokenIndex],
                        _fee
                    );

                    // Check reserves, fees and expected amount
                    if (
                        amount > _reserves()[receiveTokenIndex] ||
                        amount == 0 ||
                        poolFee == 0 && _fee.pool_numerator > 0 ||
                        beneficiaryFee == 0 && _fee.beneficiary_numerator > 0
                    ) {
                        errorCode = DirectOperationErrors.INVALID_RECEIVED_AMOUNT;
                    } else if (amount < expectedAmount) {
                        errorCode = DirectOperationErrors.RECEIVED_AMOUNT_IS_LESS_THAN_EXPECTED;
                    } else {
                        // Process exchange
                        _exchangeBase(
                            id,
                            false,
                            spentTokenIndex,
                            receiveTokenIndex,
                            _tokensAmount,
                            beneficiaryFee,
                            poolFee,
                            amount,
                            _senderAddress,
                            _remainingGasTo,
                            recipient
                        );

                        // Transfer incoming token to vault
                        ITokenWallet(msg.sender)
                        .transfer{ value: DexGas.TRANSFER_TOKENS_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                        (
                            _tokensAmount,
                            _vaultRoot(),
                            0,
                            _remainingGasTo,
                            false,
                            empty
                        );

                        IDexVault(_vaultRoot())
                        .transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
                        (
                            amount,
                            _tokenRoots()[receiveTokenIndex],
                            _typeToWalletAddresses[DexAddressType.VAULT][receiveTokenIndex],
                            recipient,
                            deployWalletGrams,
                            notifySuccess,
                            PairPayload.buildSuccessPayload(op, successPayload, _senderAddress),
                            _tokenRoots()[spentTokenIndex],
                            _tokenRoots()[receiveTokenIndex],
                            _currentVersion,
                            _remainingGasTo
                        );
                    }
                } else if (op == DexOperationTypes.DEPOSIT_LIQUIDITY || op == DexOperationTypes.DEPOSIT_LIQUIDITY_V2) {
                    // Calculate deposit result
                    (
                    DepositLiquidityResult r,
                    uint128 step2PoolFee,
                    uint128 step2BeneficiaryFee
                    ) = Math.calculateExpectedDepositLiquidity(
                        _tokensAmount,
                        0,
                        true,
                        _reserves()[spentTokenIndex],
                        _reserves()[receiveTokenIndex],
                        _lpReserve(),
                        _fee
                    );

                    // Check reserves, fees and expected amount
                    if (
                        r.step_3_lp_reward > 0 &&
                        r.step_3_lp_reward >= expectedAmount &&
                        r.step_2_received <= _reserves()[receiveTokenIndex] &&
                        r.step_2_received > 0 &&
                        (step2PoolFee > 0 || _fee.pool_numerator == 0) &&
                        (step2BeneficiaryFee > 0 || _fee.beneficiary_numerator == 0)
                    )
                        if (
                            r.step_3_lp_reward == 0 ||
                            r.step_2_received > _reserves()[receiveTokenIndex] ||
                            r.step_2_received == 0 ||
                            step2PoolFee == 0 && _fee.pool_numerator > 0 ||
                            step2BeneficiaryFee == 0 && _fee.beneficiary_numerator > 0
                        ) {
                            errorCode = DirectOperationErrors.INVALID_RECEIVED_AMOUNT;
                        } else if (r.step_3_lp_reward < expectedAmount) {
                            errorCode = DirectOperationErrors.RECEIVED_AMOUNT_IS_LESS_THAN_EXPECTED;
                        } else {
                            _exchangeBase(
                                id,
                                false,
                                spentTokenIndex,
                                receiveTokenIndex,
                                _tokensAmount,
                                step2BeneficiaryFee,
                                step2PoolFee,
                                0,
                                _senderAddress,
                                _remainingGasTo,
                                recipient
                            );

                            _depositLiquidityBase(
                                id,
                                false,
                                r,
                                _senderAddress,
                                recipient
                            );

                            ITokenWallet(msg.sender)
                            .transfer{ value: DexGas.TRANSFER_TOKENS_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                            (
                                _tokensAmount,
                                _vaultRoot(),
                                0,
                                _remainingGasTo,
                                false,
                                empty
                            );

                            ITokenRoot(_lpRoot())
                            .mint{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
                            (
                                r.step_3_lp_reward,
                                recipient,
                                deployWalletGrams,
                                _remainingGasTo,
                                notifySuccess,
                                PairPayload.buildSuccessPayload(op, successPayload, _senderAddress)
                            );
                        }
                } else if (op == DexOperationTypes.CROSS_PAIR_EXCHANGE || op == DexOperationTypes.CROSS_PAIR_EXCHANGE_V2) {

                    if (nextSteps.length == 0) errorCode = DirectOperationErrors.INVALID_NEXT_STEPS;

                    if (errorCode == 0 && op == DexOperationTypes.CROSS_PAIR_EXCHANGE) {
                        // actually poolRoot is a tokenRoot here, so
                        nextSteps[0].poolRoot = _expectedPairAddress([_tokenRoots()[receiveTokenIndex], nextSteps[0].poolRoot]);
                    }

                    // Calculate exchange result
                    (
                    uint128 amount,
                    uint128 poolFee,
                    uint128 beneficiaryFee
                    ) = Math.calculateExpectedExchange(
                        _tokensAmount,
                        _reserves()[spentTokenIndex],
                        _reserves()[receiveTokenIndex],
                        _fee
                    );

                    uint256 denominator = 0;
                    uint32 allNestedNodes = uint32(nextSteps.length);
                    uint32 allLeaves = 0;
                    uint32 maxNestedNodes = 0;
                    uint32 maxNestedNodesIdx = 0;
                    for (uint32 i = 0; i < nextSteps.length; i++) {
                        NextExchangeData nextStep = nextSteps[i];
                        if (nextStep.poolRoot.value == 0 || nextStep.poolRoot == address(this) ||
                        nextStep.numerator == 0 || nextStep.leaves == 0) {

                            errorCode = DirectOperationErrors.INVALID_NEXT_STEPS;
                            break;
                        }
                        if (nextStep.nestedNodes > maxNestedNodes) {
                            maxNestedNodes = nextStep.nestedNodes;
                            maxNestedNodesIdx = i;
                        }
                        denominator += nextStep.numerator;
                        allNestedNodes += nextStep.nestedNodes;
                        allLeaves += nextStep.leaves;
                    }

                    // Check reserves, fees, msg.value and expected amount
                    if (errorCode == 0 && msg.value < DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE * (1 + allNestedNodes)) {
                        errorCode = DirectOperationErrors.VALUE_TOO_LOW;
                    } else if (
                        amount > _reserves()[receiveTokenIndex] ||
                        amount == 0 ||
                        poolFee == 0 && _fee.pool_numerator > 0 ||
                        beneficiaryFee == 0 && _fee.beneficiary_numerator > 0
                    ) {
                        errorCode = DirectOperationErrors.INVALID_RECEIVED_AMOUNT;
                    } else if (amount < expectedAmount) {
                        errorCode = DirectOperationErrors.RECEIVED_AMOUNT_IS_LESS_THAN_EXPECTED;
                    }

                    if (errorCode == 0) {
                        // Process exchange
                        _exchangeBase(
                            id,
                            false,
                            spentTokenIndex,
                            receiveTokenIndex,
                            _tokensAmount,
                            beneficiaryFee,
                            poolFee,
                            amount,
                            _senderAddress,
                            _remainingGasTo,
                            recipient
                        );

                        // Transfer incoming token to vault
                        ITokenWallet(msg.sender)
                        .transfer{ value: DexGas.TRANSFER_TOKENS_VALUE, flag: MsgFlag.SENDER_PAYS_FEES }
                        (
                            _tokensAmount,
                            _vaultRoot(),
                            0,
                            _remainingGasTo,
                            false,
                            empty
                        );

                        // Continue cross-pair exchange
                        uint128 extraValue = msg.value - DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE * (1 + allNestedNodes);

                        for (uint32 i = 0; i < nextSteps.length; i++) {
                            NextExchangeData nextStep = nextSteps[i];

                            uint128 nextPoolAmount = uint128(math.muldiv(amount, nextStep.numerator, denominator));
                            uint128 currentExtraValue = math.muldiv(nextStep.leaves, extraValue, allLeaves);

                            IDexBasePool(nextStep.poolRoot).crossPoolExchange{
                                value: i == maxNestedNodesIdx ? 0 : (nextStep.nestedNodes + 1) * DexGas.CROSS_POOL_EXCHANGE_MIN_VALUE + currentExtraValue,
                                flag: i == maxNestedNodesIdx ? MsgFlag.ALL_NOT_RESERVED : MsgFlag.SENDER_PAYS_FEES
                            }(
                                id,
                                _currentVersion,
                                DexPoolTypes.CONSTANT_PRODUCT,
                                _tokenRoots(),
                                op,
                                _tokenRoots()[receiveTokenIndex],
                                nextPoolAmount,
                                _senderAddress,
                                recipient,
                                _remainingGasTo,
                                deployWalletGrams,
                                nextStep.payload,
                                notifySuccess,
                                successPayload,
                                notifyCancel,
                                cancelPayload
                            );
                        }
                    }
                } else {
                    errorCode = DirectOperationErrors.WRONG_OPERATION_TYPE;
                }
            } else if (op == DexOperationTypes.WITHDRAW_LIQUIDITY || op == DexOperationTypes.WITHDRAW_LIQUIDITY_V2) {
                // Calculate withdrawal result
                uint128 leftBackAmount =  math.muldiv(_reserves()[0], _tokensAmount, _lpReserve());
                uint128 rightBackAmount = math.muldiv(_reserves()[1], _tokensAmount, _lpReserve());

                // Check expected amounts
                if (
                    leftBackAmount < expectedAmounts[0] ||
                    rightBackAmount < expectedAmounts[1]
                ) {
                    errorCode = DirectOperationErrors.RECEIVED_AMOUNT_IS_LESS_THAN_EXPECTED;
                } else {
                    _withdrawBase(
                        id,
                        false,
                        _tokensAmount,
                        _senderAddress,
                        recipient,
                        _remainingGasTo,
                        deployWalletGrams,
                        notifySuccess,
                        PairPayload.buildSuccessPayload(op, successPayload, _senderAddress)
                    );

                    // Burn LP tokens
                    IBurnableTokenWallet(msg.sender)
                    .burn{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
                    (
                        _tokensAmount,
                        _remainingGasTo,
                        address.makeAddrStd(0, 0),
                        empty
                    );
                }
            } else {
                errorCode = DirectOperationErrors.WRONG_OPERATION_TYPE;
            }
        }

        if (errorCode != 0) {
            // Send callback about failed operation to user
            IDexPairOperationCallback(_senderAddress)
            .dexPairOperationCancelled{
                value: DexGas.OPERATION_CALLBACK_BASE,
                flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                bounce: false
            }(id);

            if (recipient != _senderAddress) {
                IDexPairOperationCallback(recipient)
                .dexPairOperationCancelled{
                    value: DexGas.OPERATION_CALLBACK_BASE,
                    flag: MsgFlag.SENDER_PAYS_FEES + MsgFlag.IGNORE_ERRORS,
                    bounce: false
                }(id);
            }

            // Refund incoming token
            ITokenWallet(msg.sender)
            .transferToWallet{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
            (
                _tokensAmount,
                _senderWallet,
                _remainingGasTo,
                notifyCancel,
                PairPayload.buildCancelPayload(op, errorCode, cancelPayload, nextSteps)
            );
        }
    }

    function _checkOperationData(
        address _msgSender,
        uint128 _msgValue,
        bool _isPayloadValid,
        uint128 _deployWalletGrams,
        uint8 op,
        address _tokenRoot
    ) private view returns (uint16) {

        if (!_active) return DirectOperationErrors.NOT_ACTIVE;
        if (!_isPayloadValid) return DirectOperationErrors.INVALID_PAYLOAD;
        if (_lpReserve() == 0) return DirectOperationErrors.NON_POSITIVE_LP_SUPPLY;
        if (_msgValue < DexGas.DIRECT_PAIR_OP_MIN_VALUE_V2 + _deployWalletGrams) return DirectOperationErrors.VALUE_TOO_LOW;

        if (_tokenRoot == _lpRoot() && _msgSender != _typeToWalletAddresses[DexAddressType.LP][0]) return DirectOperationErrors.NOT_LP_TOKEN_WALLET;
        if (_tokenRoot != _lpRoot()) {
            if (_tokenRoot != _tokenRoots()[0] && _tokenRoot != _tokenRoots()[1]) return DirectOperationErrors.NOT_TOKEN_ROOT;
            if (_msgSender != _typeToWalletAddresses[DexAddressType.RESERVE][0] && _msgSender != _typeToWalletAddresses[DexAddressType.RESERVE][1]) return DirectOperationErrors.NOT_TOKEN_WALLET;
        }

        if (!(_msgSender == _typeToWalletAddresses[DexAddressType.LP][0] && (op == DexOperationTypes.WITHDRAW_LIQUIDITY || op == DexOperationTypes.WITHDRAW_LIQUIDITY_V2) ||
        _msgSender != _typeToWalletAddresses[DexAddressType.LP][0] && (
        op == DexOperationTypes.DEPOSIT_LIQUIDITY || op == DexOperationTypes.DEPOSIT_LIQUIDITY_V2 ||
        op == DexOperationTypes.EXCHANGE || op == DexOperationTypes.EXCHANGE_V2 ||
        op == DexOperationTypes.CROSS_PAIR_EXCHANGE || op == DexOperationTypes.CROSS_PAIR_EXCHANGE_V2
        )
        )) return DirectOperationErrors.WRONG_OPERATION_TYPE;

        if ((op == DexOperationTypes.WITHDRAW_LIQUIDITY || op == DexOperationTypes.WITHDRAW_LIQUIDITY_V2) && _msgValue < DexGas.DIRECT_PAIR_OP_MIN_VALUE_V2 + 2 * _deployWalletGrams) {
            return DirectOperationErrors.VALUE_TOO_LOW;
        }

        return 0;
    }

    function upgrade(
        TvmCell _code,
        uint32 _newVersion,
        uint8 _newType,
        address _remainingGasTo
    ) override external onlyRoot {
        if (
            _currentVersion == _newVersion &&
            _newType == DexPoolTypes.CONSTANT_PRODUCT
        ) {
            tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);

            _remainingGasTo.transfer({
                value: 0,
                flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
                bounce: false
            });
        } else {
            if (_fee.beneficiary.value != 0) {
                _processBeneficiaryFees(true, _remainingGasTo);
            }

            emit PairCodeUpgraded(_newVersion, _newType);

            TvmBuilder builder;

            builder.store(_root);
            builder.store(_typeToRootAddresses[DexAddressType.VAULT][0]);
            builder.store(_currentVersion);
            builder.store(_newVersion);
            builder.store(_remainingGasTo);
            builder.store(DexPoolTypes.CONSTANT_PRODUCT);
            builder.store(platform_code);  // ref1 = platform_code

            //Tokens
            TvmBuilder tokens_data_builder;
            tokens_data_builder.store(_typeToRootAddresses[DexAddressType.RESERVE][0]);
            tokens_data_builder.store(_typeToRootAddresses[DexAddressType.RESERVE][1]);
            builder.storeRef(tokens_data_builder);  // ref2

            TvmCell other_data = abi.encode(
                _typeToRootAddresses[DexAddressType.LP][0],
                _typeToWalletAddresses[DexAddressType.LP][0],
                _typeToReserves[DexReserveType.LP][0],

                FeeParamsPrev(_fee.denominator, _fee.pool_numerator, _fee.beneficiary_numerator, _fee.beneficiary, _fee.threshold),

                _typeToWalletAddresses[DexAddressType.RESERVE][0],
                _typeToWalletAddresses[DexAddressType.VAULT][0],
                _typeToReserves[DexReserveType.POOL][0],

                _typeToWalletAddresses[DexAddressType.RESERVE][1],
                _typeToWalletAddresses[DexAddressType.VAULT][1],
                _typeToReserves[DexReserveType.POOL][1]
            );

            builder.store(other_data);   // ref3
            builder.store(_packAllOracleData());    // ref4

            // set code after complete this method
            tvm.setcode(_code);
            tvm.setCurrentCode(_code);

            onCodeUpgrade(builder.toCell());
        }
    }

    /// @dev Restores old data after contract's code update
    /// @param _data Old encoded data
    function onCodeUpgrade(TvmCell _data) private {
        tvm.rawReserve(DexGas.PAIR_INITIAL_BALANCE, 0);
        tvm.resetStorage();

        TvmSlice dataSlice = _data.toSlice();

        address vault;
        address remainingGasTo;
        uint32 oldVersion;
        uint8 oldPoolType = DexPoolTypes.CONSTANT_PRODUCT;

        // Unpack base data
        (
            _root,
            vault,
            oldVersion,
            _currentVersion,
            remainingGasTo
        ) = dataSlice.decode(
            address,
            address,
            uint32,
            uint32,
            address
        );

        _typeToRootAddresses[DexAddressType.VAULT].push(vault);

        if (dataSlice.bits() >= 8) {
            oldPoolType = dataSlice.decode(uint8);
        }

        // Load platform's code
        platform_code = dataSlice.loadRef(); // ref 1

        address leftRoot;
        address rightRoot;

        // Load tokens' roots addresses
        TvmSlice tokensDataSlice = dataSlice.loadRefAsSlice(); // ref 2
        (leftRoot, rightRoot) = tokensDataSlice.decode(address, address);

        // Set token roots and fee reserves
        _typeToRootAddresses[DexAddressType.RESERVE].push(leftRoot);
        _typeToRootAddresses[DexAddressType.RESERVE].push(rightRoot);
        _typeToReserves[DexReserveType.FEE].push(0);
        _typeToReserves[DexReserveType.FEE].push(0);

        if (oldVersion == 0) {
            // Set initial params for fees
            _fee = FeeParams(1000000, 3000, 0, 0, address(0), emptyMap);

            // Deploy LP token for pair
            IDexVault(_typeToRootAddresses[DexAddressType.VAULT][0])
            .addLiquidityToken{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED }
            (
                address(this),
                _typeToRootAddresses[DexAddressType.RESERVE][0],
                _typeToRootAddresses[DexAddressType.RESERVE][1],
                remainingGasTo
            );

            _initializeTWAPOracle(now);
        } else if (oldPoolType == DexPoolTypes.CONSTANT_PRODUCT) {
            _active = true;
            TvmCell otherData = dataSlice.loadRef(); // ref 3

            address lpRoot;
            address lpWallet;
            address leftWallet;
            address vaultLeftWallet;
            address rightWallet;
            address vaultRightWallet;
            uint128 lpSupply;
            uint128 leftBalance;
            uint128 rightBalance;

            FeeParamsPrev feePrev;

            // Decode reserves, wallets and fee options
            (
                lpRoot, lpWallet, lpSupply,
                feePrev,
                leftWallet, vaultLeftWallet, leftBalance,
                rightWallet, vaultRightWallet, rightBalance
            ) = abi.decode(otherData, (
                address, address, uint128,
                FeeParamsPrev,
                address, address, uint128,
                address, address, uint128
                ));

            _fee = FeeParams(feePrev.denominator, feePrev.pool_numerator, feePrev.beneficiary_numerator, 0, feePrev.beneficiary, feePrev.threshold);

            // Set lp reserve and wallet
            _typeToRootAddresses[DexAddressType.LP].push(lpRoot);
            _typeToWalletAddresses[DexAddressType.LP].push(lpWallet);
            _typeToReserves[DexReserveType.LP].push(lpSupply);

            // Set left reserve and wallet
            _typeToWalletAddresses[DexAddressType.RESERVE].push(leftWallet);
            _typeToWalletAddresses[DexAddressType.VAULT].push(vaultLeftWallet);
            _typeToReserves[DexReserveType.POOL].push(leftBalance);

            // Set right reserve and wallet
            _typeToWalletAddresses[DexAddressType.RESERVE].push(rightWallet);
            _typeToWalletAddresses[DexAddressType.VAULT].push(vaultRightWallet);
            _typeToReserves[DexReserveType.POOL].push(rightBalance);

            if (dataSlice.refs() > 0) {
                TvmSlice oracleDataSlice = dataSlice.loadRefAsSlice();  // ref 4

                (
                    _points,
                    _options,
                    _length
                ) = oracleDataSlice.decode(
                    mapping(uint32 => Point),
                    OracleOptions,
                    uint16
                );
            }
        } else if (oldPoolType == DexPoolTypes.STABLESWAP) {
            _active = true;
            TvmCell otherData = dataSlice.loadRef(); // ref 3
            IPoolTokenData.PoolTokenData[] tokensData = new IPoolTokenData.PoolTokenData[](2);

            address lpRoot;
            address lpWallet;
            uint128 lpSupply;

            // Set lp reserve and fee options
            (
                lpRoot, lpWallet, lpSupply,
                _fee,
                tokensData,,
            ) = abi.decode(otherData, (
                address, address, uint128,
                FeeParams,
                IPoolTokenData.PoolTokenData[],
                IAmplificationCoefficient.AmplificationCoefficient,
                uint256
                ));

            // Set lp reserve
            _typeToReserves[DexReserveType.LP].push(lpSupply);

            // Set left reserve and wallet
            _typeToWalletAddresses[DexAddressType.RESERVE].push(tokensData[0].wallet);
            _typeToWalletAddresses[DexAddressType.VAULT].push(tokensData[0].vaultWallet);
            _typeToReserves[DexReserveType.POOL].push(tokensData[0].balance);

            // Set right reserve and wallet
            _typeToWalletAddresses[DexAddressType.RESERVE].push(tokensData[1].wallet);
            _typeToWalletAddresses[DexAddressType.VAULT].push(tokensData[1].vaultWallet);
            _typeToReserves[DexReserveType.POOL].push(tokensData[1].balance);

            _initializeTWAPOracle(now);
        }

        // Refund remaining gas
        remainingGasTo.transfer({
            value: 0,
            flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
            bounce: false
        });
    }

    /// @dev Deploys wallet by TIP-3 token root and wait for callback
    /// @param _tokenRoot Address of the TIP-3 TokenRoot for a new wallet deploy
    function _configureTokenRootWallets(address _tokenRoot) private view {
        ITokenRoot(_tokenRoot)
        .deployWallet{
            value: DexGas.DEPLOY_EMPTY_WALLET_VALUE,
            flag: MsgFlag.SENDER_PAYS_FEES,
            callback: DexPairLpWithdrawal.onTokenWallet
        }(address(this), DexGas.DEPLOY_EMPTY_WALLET_GRAMS);

        // Request wallet's address
        if (_tokenRoot != _typeToRootAddresses[DexAddressType.LP][0]) {
            ITokenRoot(_tokenRoot)
            .walletOf{
                value: DexGas.SEND_EXPECTED_WALLET_VALUE,
                flag: MsgFlag.SENDER_PAYS_FEES,
                callback: DexPairLpWithdrawal.onVaultTokenWallet
            }(_typeToRootAddresses[DexAddressType.VAULT][0]);
        }
    }

    /// @dev Will activate pair if all wallets' addresses are set
    function _tryToActivate() private {
        if (
            _typeToWalletAddresses[DexAddressType.LP].length == 1 &&
            _typeToWalletAddresses[DexAddressType.RESERVE].length == 2 &&
            _typeToWalletAddresses[DexAddressType.VAULT].length == 2
        ) {
            _active = true;
        }
    }
}
