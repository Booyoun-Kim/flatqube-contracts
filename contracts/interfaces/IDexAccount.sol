pragma ton-solidity >= 0.57.0;

import "./ISuccessCallback.sol";
import "../structures/ITokenOperationStructure.sol";

interface IDexAccount is ISuccessCallback, ITokenOperationStructure {
    struct WithdrawalParams {
        uint64  call_id;
        address recipient_address;
        uint128 deploy_wallet_grams;
    }

    struct Operation {
        TokenOperation[] token_operations;
        address send_gas_to;
        address expected_callback_sender;
    }

    event AddPair(address left_root, address right_root, address pair);
    event AddPairV2(address[] roots, address pair);

    event WithdrawTokens(address root, uint128 amount, uint128 balance);
    event TransferTokens(address root, uint128 amount, uint128 balance);
    event ExchangeTokens(address from, address to, uint128 spent_amount, uint128 expected_amount, uint128 balance);
    event DepositLiquidity(
        address left_root,
        uint128 left_amount,
        address right_root,
        uint128 right_amount,
        bool auto_change
    );
    event DepositLiquidityV2(
        TokenOperation[] operations,
        bool autoChange
    );

    event WithdrawLiquidity(
        uint128 lp_amount,
        uint128 lp_balance,
        address lp_root,
        address left_root,
        address right_root
    );
    event WithdrawLiquidityV2(
        uint128 lpAmount,
        uint128 lpBalance,
        address lpRoot,
        address[] roots
    );

    event TokensReceived(address token_root, uint128 tokens_amount, uint128 balance, address sender_wallet);
    event TokensReceivedFromAccount(address token_root, uint128 tokens_amount, uint128 balance, address sender);
    event TokensReceivedFromPair(
        address token_root,
        uint128 tokens_amount,
        uint128 balance,
        address left_root,
        address right_root
    );
    event TokensReceivedFromPairV2(
        address tokenRoot,
        uint128 tokensAmount,
        uint128 balance,
        address[] roots
    );

    event OperationRollback(address token_root, uint128 amount, uint128 balance, address from);
    event ExpectedPairNotExist(address pair);

    event AccountCodeUpgraded(uint32 version);
    event CodeUpgradeRequested();
    event GarbageCollected();

    function getRoot() external view responsible returns (address);

    function getOwner() external view responsible returns (address);

    function getVersion() external view responsible returns (uint32);

    function getVault() external view responsible returns (address);

    function getWalletData(address token_root) external view responsible returns (address wallet, uint128 balance);

    function withdraw(
        uint64  call_id,
        uint128 amount,
        address token_root,
        address recipient_address,
        uint128 deploy_wallet_grams,
        address send_gas_to
    ) external;

    function transfer(
        uint64  call_id,
        uint128 amount,
        address token_root,
        address to_dex_account,
        bool    willing_to_deploy,
        address send_gas_to
    ) external;

    function exchange(
        uint64  call_id,
        uint128 spent_amount,
        address spent_token_root,
        address receive_token_root,
        uint128 expected_amount,
        address send_gas_to
    ) external;
    function exchangeV2(
        uint64 _callId,
        uint128 _spentAmount,
        address _spentTokenRoot,
        address _receiveTokenRoot,
        uint128 _expectedAmount,
        address[] _roots,
        address _remainingGasTo
    ) external;

    function withdrawLiquidity(
        uint64  call_id,
        uint128 lp_amount,
        address lp_root,
        address left_root,
        address right_root,
        address send_gas_to
    ) external;
    function withdrawLiquidityV2(
        uint64 _callId,
        uint128 _lpAmount,
        address _lpRoot,
        TokenOperation[] _expected,
        address _remainingGasTo
    ) external;

    function depositLiquidity(
        uint64  call_id,
        address left_root,
        uint128 left_amount,
        address right_root,
        uint128 right_amount,
        address expected_lp_root,
        bool    auto_change,
        address send_gas_to
    ) external;
    function depositLiquidityV2(
        uint64 _callId,
        TokenOperation[] _operations,
        address _expectedLpRoot,
        uint128 _expectedLpAmount,
        bool _autoChange,
        address _remainingGasTo
    ) external;

    function addPair(
        address left_root,
        address right_root
    ) external;
    function addPool(address[] _roots) external;

    //////////////////////////////////////////////////////////////////////////////////////////////////////
    // INTERNAL

    function checkPoolCallback(
        address[] _roots,
        address _lpRoot
    ) external;

    function internalAccountTransfer(
        uint64 call_id,
        uint128 amount,
        address token_root,
        address sender_owner,
        bool    willing_to_deploy,
        address send_gas_to
    ) external;

    function internalPairTransfer(
        uint128 amount,
        address token_root,
        address sender_left_root,
        address sender_right_root,
        address send_gas_to
    ) external;

    function internalPoolTransfer(
        uint128 _amount,
        address _tokenRoot,
        address[] _roots,
        address _remainingGasTo
    ) external;
}
