pragma ton-solidity ^0.39.0;

pragma AbiHeader time;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import '../node_modules/ton-eth-bridge-token-contracts/free-ton/contracts/interfaces/IRootTokenContract.sol';
import '../node_modules/ton-eth-bridge-token-contracts/free-ton/contracts/interfaces/ITONTokenWallet.sol';
import "../node_modules/ton-eth-bridge-token-contracts/free-ton/contracts/interfaces/ITokensReceivedCallback.sol";
import "../node_modules/ton-eth-bridge-token-contracts/free-ton/contracts/interfaces/IExpectedWalletAddressCallback.sol";

import "./libraries/PlatformTypes.sol";
import "./libraries/DexErrors.sol";
import "./libraries/Gas.sol";

import "./interfaces/IUpgradableByRequest.sol";
import "./interfaces/IDexRoot.sol";
import "./interfaces/IDexPair.sol";
import "./interfaces/IDexAccount.sol";
import "./interfaces/IDexVault.sol";
import "./interfaces/IResetGas.sol";
import "./interfaces/IAfterInitialize.sol";

import "./DexPlatform.sol";

contract DexPair is IDexPair, IExpectedWalletAddressCallback, IUpgradableByRequest, IAfterInitialize, IResetGas {

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Data

    // Base:
    address root;
    address vault;
    uint32 current_version;
    TvmCell platform_code;

    // Params:
    address left_root;
    address right_root;

    // Custom:
    bool active;
    // Liquidity tokens
    address lp_root;
    address lp_wallet;
    uint128 lp_supply;
    // Balances
    uint128 left_balance;
    uint128 right_balance;
    // Fee
    uint16 fee_nominator = 3;
    uint16 fee_denominator = 1000;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Base functions

    // Cant be deployed directly
    constructor() public { revert(); }

    // Prevent manual transfers
    receive() external pure { revert(); }

    // Prevent undefined functions call, need for bounce future Account/Root functions calls, when not upgraded
    fallback() external pure { revert();  }

    // ...and allow root to get surplus gas
    function resetGas(address receiver) override external view onlyRoot {
        tvm.rawReserve(Gas.PAIR_INITIAL_BALANCE, 2);
        receiver.transfer({ value: 0, flag: 128 });
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Getters

    function getRoot() override external view responsible returns (address) {
        return { value: 0, bounce: false, flag: 64 } root;
    }

    function getTokenRoots() override external view responsible returns (address left, address right, address lp) {
        return { value: 0, bounce: false, flag: 64 } (left_root, right_root, lp_root);
    }

    function getVersion() override external view responsible returns (uint32) {
        return { value: 0, bounce: false, flag: 64 } current_version;
    }

    function getVault() override external view responsible returns (address) {
        return { value: 0, bounce: false, flag: 64 } vault;
    }

    function getFeeParams() override external view responsible returns (uint16 nominator, uint16 denominator) {
        return { value: 0, bounce: false, flag: 64 } (fee_nominator, fee_denominator);
    }

    function isActive() override external view responsible returns (bool) {
        return { value: 0, bounce: false, flag: 64 } active;
    }

    // TODO:

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Deposit liquidity

    function expectedDepositLiquidity(
        uint128 left_amount,
        uint128 right_amount,
        bool auto_change
    ) override external view responsible returns (DepositLiquidityResult) {
        return { value: 0, bounce: false, flag: 64 } _expectedDepositLiquidity(left_amount, right_amount, auto_change);
    }

    function depositLiquidity(
        uint64 call_id,
        uint128 left_amount,
        uint128 right_amount,
        address account_owner,
        uint32 account_version,
        address send_gas_to
    ) override external onlyActive onlyAccount(account_owner) {
        // TODO
    }

   function _expectedDepositLiquidity(
        uint128 left_amount,
        uint128 right_amount,
        bool auto_change
    ) private inline view returns (DepositLiquidityResult) {
        // step 1 (first deposit)
        uint128 step_1_left_deposit = math.min(left_amount, math.muldiv(left_balance, right_amount, right_balance));
        uint128 step_1_right_deposit = math.min(right_amount, math.muldiv(right_balance, left_amount, left_balance));
        uint128 step_1_lp_reward = math.max(
            math.muldiv(step_1_right_deposit, lp_supply, right_balance),
            math.muldiv(step_1_left_deposit, lp_supply, left_balance)
        );

        uint128 current_left_amount = left_amount - step_1_left_deposit;
        uint128 current_right_amount = right_amount - step_1_right_deposit;
        uint128 current_left_balance = left_balance + step_1_left_deposit;
        uint128 current_right_balance = right_balance + step_1_right_deposit;
        uint128 current_lp_supply = lp_supply + step_1_lp_reward;

        bool step_2_left_to_right = false;
        bool step_2_right_to_left = false;
        uint128 step_2_spent = 0;
        uint128 step_2_fee = 0;
        uint128 step_2_received = 0;

        uint128 step_3_left_deposit = 0;
        uint128 step_3_right_deposit = 0;
        uint128 step_3_lp_reward = 0;

        uint256 fee_d_minus_n = uint256(fee_denominator - fee_nominator);

        if (auto_change && current_right_amount > 0) {
            // step 2 (surplus TON exchange)
            step_2_right_to_left = true;
            uint256 p = math.muldiv(current_right_balance, fee_d_minus_n + fee_denominator, fee_d_minus_n);
            uint256 q = math.muldiv(current_right_amount * current_right_balance, fee_denominator, fee_d_minus_n);
            step_2_spent = _solveQuadraticEquationPQ(p, q);
            (step_2_received, step_2_fee) = _expectedExchange(step_2_spent, current_right_balance, current_left_balance);

            current_right_amount = current_right_amount - step_2_spent;
            current_right_balance = current_right_balance + step_2_spent;

            // step 3 (deposit exchanged amounts)
            step_3_right_deposit = current_right_amount;
            step_3_left_deposit = step_2_received;

            step_3_lp_reward = math.muldiv(current_right_amount, current_lp_supply, current_right_balance);
        } else if (auto_change && current_left_amount > 0) {
            // step 2 (surplus tokens exchange)
            step_2_left_to_right = true;
            uint256 p = math.muldiv(current_left_balance, fee_d_minus_n + fee_denominator, fee_d_minus_n);
            uint256 q = math.muldiv(current_left_amount * current_left_balance, fee_denominator, fee_d_minus_n);
            step_2_spent = _solveQuadraticEquationPQ(p, q);
            (step_2_received, step_2_fee) = _expectedExchange(step_2_spent, current_left_balance, current_right_balance);

            current_left_amount = current_left_amount - step_2_spent;
            current_left_balance = current_left_balance + step_2_spent;

            // step 3 (deposit exchanged amounts)
            step_3_left_deposit = current_left_amount;
            step_3_right_deposit = step_2_received;

            step_3_lp_reward = math.muldiv(current_left_amount, current_lp_supply, current_left_balance);
        }

        return DepositLiquidityResult(
            step_1_left_deposit,
            step_1_right_deposit,
            step_1_lp_reward,

            step_2_left_to_right,
            step_2_right_to_left,
            step_2_spent,
            step_2_fee,
            step_2_received,

            step_3_left_deposit,
            step_3_right_deposit,
            step_3_lp_reward
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Withdraw liquidity
    // TODO:

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Exchange

    function expectedLeftToRight(uint128 left_amount) external view returns (uint128 expected_right_amount, uint128 expected_left_fee) {
        return _expectedExchange(left_amount, left_balance, right_balance);
    }

    function expectedRightToLeft(uint128 right_amount) external view returns (uint128 expected_left_amount, uint128 expected_right_fee) {
        return _expectedExchange(right_amount, right_balance, left_balance);
    }

    function exchange(
        uint64 call_id,
        uint128 spent_amount,
        address spent_token_root,
        address receive_token_root,
        uint128 expected_amount,
        address account_owner,
        uint32 account_version,
        address send_gas_to
    ) override external onlyActive onlyAccount(account_owner) {
        // TODO:
    }

    function _expectedExchange(uint128 a_amount, uint128 a_pool, uint128 b_pool) private inline view returns (uint128, uint128) {
        uint128 a_fee = math.muldiv(a_amount, fee_nominator, fee_denominator);

        uint128 new_a_pool = a_pool + a_amount;
        uint128 new_b_pool = math.muldiv(a_pool, b_pool, new_a_pool - a_fee);
        uint128 expected_b_amount = b_pool - new_b_pool;

        return (expected_b_amount, a_fee);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Account operations

    function checkPair(
        uint64 call_id,
        address account_owner,
        uint32 /*account_version*/,
        address send_gas_to
    ) override external onlyActive {
        address expected = address(tvm.hash(_buildInitData(
                PlatformTypes.Account,
                _buildAccountParams(account_owner)
            )));
        require(msg.sender == expected, DexErrors.NOT_ACCOUNT);

        tvm.rawReserve(Gas.PAIR_INITIAL_BALANCE, 2);

        IDexAccount(expected).checkPairCallback{value: 0, flag: 128}(call_id, left_root, right_root, lp_root, send_gas_to);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Modifiers

    modifier onlyActive() {
        require(active, DexErrors.NOT_ACTIVE);
        _;
    }

    modifier onlyLiquidityTokenRoot() {
        require(msg.sender == lp_root, DexErrors.NOT_LP_TOKEN_ROOT);
        _;
    }

    modifier onlyTokenRoot() {
        require(msg.sender == left_root || msg.sender == right_root, DexErrors.NOT_TOKEN_ROOT);
        _;
    }

    modifier onlyRoot() {
        require(msg.sender == root, DexErrors.NOT_ROOT);
        _;
    }

    modifier onlyVault() {
        require(msg.sender == vault, DexErrors.NOT_VAULT);
        _;
    }

    modifier onlyAccount(address account_owner) {
        address expected = address(tvm.hash(_buildInitData(
                PlatformTypes.Account,
                _buildAccountParams(account_owner)
            )));
        require(msg.sender == expected, DexErrors.NOT_ACCOUNT);
        _;
    }

    modifier onlyPair(address left_root_, address right_root_) {
        address expected = address(tvm.hash(_buildInitData(
                PlatformTypes.Pair,
                _buildPairParams(left_root_, right_root_)
            )));
        require(msg.sender == expected, DexErrors.NOT_PAIR);
        _;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Address calculations
    function _buildAccountParams(address account_owner) private inline pure returns (TvmCell) {
        TvmBuilder builder;
        builder.store(account_owner);
        return builder.toCell();
    }

    function _buildPairParams(address left_root_, address right_root_) private inline pure returns (TvmCell) {
        TvmBuilder builder;
        if (left_root_.value < right_root_.value) {
            builder.store(left_root_);
            builder.store(right_root_);
        } else {
            builder.store(right_root_);
            builder.store(left_root_);
        }
        return builder.toCell();
    }

    function _buildInitData(uint8 type_id, TvmCell params) private inline view returns (TvmCell) {
        return tvm.buildStateInit({
            contr: DexPlatform,
            varInit: {
                root: address(this),
                type_id: type_id,
                params: params
            },
            pubkey: 0,
            code: platform_code
        });
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Code upgrade

    function upgrade(TvmCell code, uint32 new_version, address send_gas_to) override external onlyRoot {
        if (current_version == new_version) {
            send_gas_to.transfer({ value: 0, flag: 128 });
        } else {
            TvmBuilder builder;

            builder.store(root);
            builder.store(vault);
            builder.store(current_version);
            builder.store(new_version);
            builder.store(send_gas_to);

            builder.store(platform_code);  // ref1 = platform_code

            TvmBuilder dataBuilder;        // ref2:
            dataBuilder.store(left_root);
            dataBuilder.store(right_root);
            dataBuilder.store(lp_root);
            // TODO:
            builder.storeRef(dataBuilder);

            // set code after complete this method
            tvm.setcode(code);

            // run onCodeUpgrade from new code
            tvm.setCurrentCode(code);
            onCodeUpgrade(builder.toCell());
        }
    }

    /*
        upgrade_data
            bits:
                uint32 old_version - zero if initialize
                uint32 new_version
                address root
                address send_gas_to
            refs:
                1: platform_code
                2: data
                    bits:
                        address left_root
                        address right_root
                        [address lp_root]
    */
    function onCodeUpgrade(TvmCell upgrade_data) private {
        TvmSlice s = upgrade_data.toSlice();
        (address root_, address vault_, uint32 old_version, uint32 new_version, address send_gas_to) =
        s.decode(address, address, uint32, uint32, address);

        if (old_version == 0) {
            tvm.resetStorage();
        }

        root = root_;
        vault = vault_;
        current_version = new_version;

        platform_code = s.loadRef();        // ref 1
        TvmSlice data = s.loadRefAsSlice(); // ref 2

        left_root = data.decode(address);
        right_root = data.decode(address);

        tvm.rawReserve(Gas.PAIR_INITIAL_BALANCE, 2);
        send_gas_to.transfer({ value: 0, flag: 128 });
    }

    function afterInitialize(address send_gas_to) override external onlyRoot {
        tvm.rawReserve(Gas.PAIR_INITIAL_BALANCE, 2);
        if (lp_root.value == 0) {
            IDexVault(vault).addLiquidityToken{ value: 0, flag: 128 }(address(this), left_root, right_root, send_gas_to);
        } else {
            send_gas_to.transfer({ value: 0, flag: 128 });
        }
    }

    function liquidityTokenRootDeployed(address lp_root_, address send_gas_to) override external onlyVault {
        tvm.rawReserve(Gas.PAIR_INITIAL_BALANCE, 2);
        lp_root = lp_root_;

        IRootTokenContract(lp_root)
        .deployEmptyWallet{ value: gasToValue(Gas.DEPLOY_EMPTY_WALLET_VALUE, lp_root.wid), flag: 1}(
            Gas.DEPLOY_EMPTY_WALLET_GRAMS,  // deploy_grams
            0,                              // wallet_public_key
            address(this),                  // owner_address
            send_gas_to                     // gas_back_address
        );
        IRootTokenContract(lp_root)
        .sendExpectedWalletAddress{ value: gasToValue(Gas.SEND_EXPECTED_WALLET_VALUE, lp_root.wid), flag: 1}(
            0,                              // wallet_public_key_
            address(this),                  // owner_address_
            address(this)                   // to
        );

        send_gas_to.transfer({ value: 0, flag: 128 });
    }

    // callback for IRootTokenContract(...).sendExpectedWalletAddress
    function expectedWalletAddressCallback(
        address wallet,
        uint256 wallet_public_key,
        address owner_address
    ) override external {
        require(msg.sender == lp_root);
        require(lp_wallet.value == 0);
        require(wallet_public_key == 0);
        require(owner_address == address(this));

        lp_wallet = wallet;

        ITONTokenWallet(wallet).setReceiveCallback{ value: 0, flag: 128}(address(this), false);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    // Math
    /*
        Solve x*x + p*x - q*x = 0;
    */
    function _solveQuadraticEquationPQ(uint256 p, uint256 q) private inline pure returns (uint128) {
        uint256 D = math.muldiv(p, p, 4) + q;
        uint256 Dsqrt = _sqrt(D);
        if (Dsqrt > (p/2)) {
            return uint128(Dsqrt - (p/2));
        } else {
            return uint128((p/2) - Dsqrt);
        }
    }

    // Babylonian method for finding sqrt
    function _sqrt(uint256 x) private inline pure returns (uint256) {
        if (x == 0) return 0;
        else if (x <= 3) return 1;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y)
        {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
