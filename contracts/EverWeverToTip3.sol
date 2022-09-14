pragma ton-solidity >= 0.57.0;

pragma AbiHeader time;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./libraries/EverToTip3Gas.sol";
import "./libraries/EverToTip3Errors.sol";
import "./libraries/EverToTip3Payloads.sol";

import "./interfaces/IEverVault.sol";
import "./structures/ITokenOperationStructure.sol";

import "@broxus/contracts/contracts/libraries/MsgFlag.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/ITokenRoot.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/ITokenWallet.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/IAcceptTokensTransferCallback.sol";
import "ton-eth-bridge-token-contracts/contracts/interfaces/IAcceptTokensBurnCallback.sol";

contract EverWeverToTip3 is IAcceptTokensTransferCallback, IAcceptTokensBurnCallback {

    uint32 static randomNonce_;

    address static public weverRoot;
    address static public weverVault;
    address static public everToTip3;

    address public weverWallet;

    constructor() public {
        tvm.accept();

        tvm.rawReserve(EverToTip3Gas.TARGET_BALANCE, 0);

        ITokenRoot(weverRoot).deployWallet{
            value: EverToTip3Gas.DEPLOY_EMPTY_WALLET_VALUE,
            flag: MsgFlag.SENDER_PAYS_FEES,
            callback: EverWeverToTip3.onWeverWallet
        }(
            address(this),
            EverToTip3Gas.DEPLOY_EMPTY_WALLET_GRAMS
        );

        msg.sender.transfer(0, false, MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS);
    }

    // Callback deploy WEVER wallet for contract
    function onWeverWallet(address _weverWallet) external {
        require(msg.sender.value != 0 && msg.sender == weverRoot, EverToTip3Errors.NOT_WEVER_ROOT);
        weverWallet = _weverWallet;
        weverWallet.transfer(0, false, MsgFlag.REMAINING_GAS + MsgFlag.IGNORE_ERRORS);
    }

    // Payload constructor swap Ever -> Tip-3
    function buildExchangePayload(
        address pair,
        uint64 id,
        uint128 deployWalletValue,
        uint128 expectedAmount,
        uint128 amount
    ) external pure returns (TvmCell) {
        return EverToTip3Payloads.buildExchangePayload(pair, id, deployWalletValue, expectedAmount, amount);
    }

    // Payload constructor swap Ever -> Tip-3 via cross-pair
    function buildCrossPairExchangePayload(
        address pair,
        uint64 id,
        uint128 deployWalletValue,
        uint128 expectedAmount,
        ITokenOperationStructure.TokenOperation[] steps,
        uint128 amount
    ) external pure returns (TvmCell) {
        return EverToTip3Payloads.buildCrossPairExchangePayload(pair, id, deployWalletValue, expectedAmount, steps, amount);
    }

     //Callback
    function onAcceptTokensTransfer(
        address /*tokenRoot*/,
        uint128 amount,
        address sender,
        address /*senderWallet*/,
        address user,
        TvmCell payload
    )
        override
        external
    {
        require(msg.sender.value != 0);

        bool needCancel = false;
        TvmSlice payloadSlice = payload.toSlice();
        tvm.rawReserve(EverToTip3Gas.TARGET_BALANCE, 0);
        if (payloadSlice.bits() == 395 && msg.sender == weverWallet) {
            (, uint128 amount_) = payloadSlice.decode(address, uint128);
            if ((amount + msg.value - EverToTip3Gas.SWAP_EVER_TO_TIP3_MIN_VALUE) >= amount_) {
                ITokenWallet(msg.sender).transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED, bounce: false }(
                    amount,
                    weverVault,
                    0,
                    user,
                    true,
                    payload
                );
            } else {
                needCancel = true;
            }
        } else {
            needCancel = true;
        }

        if (needCancel) {
            TvmCell emptyPayload;
            ITokenWallet(msg.sender).transfer{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED, bounce: false }(
                amount,
                user,
                sender != user ? 0.1 ever : 0,
                user,
                true,
                emptyPayload
            );
        }
    }

    // Callback Burn token
    function onAcceptTokensBurn(
        uint128 /*amount*/,
        address /*walletOwner*/,
        address /*wallet*/,
        address user,
        TvmCell payload
    )
        override
        external
    {
        require(msg.sender.value != 0 && msg.sender == weverRoot, EverToTip3Errors.NOT_WEVER_ROOT);
        tvm.rawReserve(EverToTip3Gas.TARGET_BALANCE, 0);

        TvmSlice payloadSlice =  payload.toSlice();
        (, uint128 amount_) = payloadSlice.decode(address, uint128);

        IEverVault(weverVault).wrap{ value: 0, flag: MsgFlag.ALL_NOT_RESERVED, bounce: false }(
            amount_,
            everToTip3,
            user,
            payload
        );
    }
}
