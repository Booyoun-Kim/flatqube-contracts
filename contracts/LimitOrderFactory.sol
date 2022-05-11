pragma ton-solidity >=0.57.0;

pragma AbiHeader time;
pragma AbiHeader expire;
pragma AbiHeader pubkey;

import "./libraries/LimitOrderGas.sol";
import "./libraries/LimitOrderErrors.sol";
import "./interfaces/ILimitOrderFactory.sol";

import "./LimitOrderRoot.sol";
import "@broxus/contracts/contracts/libraries/MsgFlag.sol";

contract LimitOrderFactory is ILimitOrderFactory {
	uint32 static randomNonce;
	address static dexRoot;

	uint32 currentVersion;
	uint32 versionLimitOrderRoot;

	address owner;
	address pendingOwner;
	
	TvmCell limitOrderRootCode;
	TvmCell limitOrderCode;
	TvmCell limitOrderCodeClosed;
	TvmCell limitOrderPlatform;

	constructor(address _owner, uint32 _version) public {
		require(_owner.value != 0);
		tvm.accept();
		tvm.rawReserve(LimitOrderGas.TARGET_BALANCE, 0);

		currentVersion = _version;
		versionLimitOrderRoot++;

		owner = _owner;
		owner.transfer({
			value: 0,
			bounce: false,
			flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		});
	}

	modifier onlyOwner() {
		require(
			msg.sender.value != 0 && msg.sender == owner,
			LimitOrderErrors.NOT_OWNER
		);
		_;
	}

	function getOwner() external view responsible returns (address) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } owner;
	}

	function getVersion() external view responsible returns (uint32) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } currentVersion;
	}

	function getPendingOwner() external view responsible returns (address) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } pendingOwner;
	}

	function limitOrderRoot() external view responsible returns (TvmCell) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } limitOrderRootCode;
	}

	function limitOrder() external view responsible returns (TvmCell) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } limitOrderCode;
	}

	function limitOrderClosed() external view responsible returns (TvmCell) {
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } limitOrderCodeClosed;
	}

	function transferOwner(address newOwner) external responsible onlyOwner returns (address) {
		pendingOwner = newOwner;
		emit RequestedOwnerTransfer(owner, pendingOwner);
		return {value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS} pendingOwner;
	}

	function acceptOwner() external responsible returns (address) {
		require(
			msg.sender.value != 0 && msg.sender == pendingOwner,
			LimitOrderErrors.NOT_PENDING_OWNER
		);
		emit OwnerTransferAccepted(owner, pendingOwner);
		owner = pendingOwner;
		pendingOwner = address(0);

		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } owner;
	}

	function setLimitOrderRootCode(TvmCell _limitOrderRootCode) public onlyOwner {
		tvm.rawReserve(LimitOrderGas.SET_CODE, 0);
		limitOrderRootCode = _limitOrderRootCode;

		emit LimitOrderRootCodeUpgraded();

		msg.sender.transfer(
			0,
			false,
			MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		);
	}

	function setLimitOrderCode(TvmCell _limitOrderCode) public onlyOwner {
		tvm.rawReserve(LimitOrderGas.SET_CODE, 0);
		limitOrderCode = _limitOrderCode;

		emit LimitOrderCodeUpgraded();

		msg.sender.transfer(
			0,
			false,
			MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		);
	}

	function setlimitOrderCodeClosed(TvmCell _limitOrderCodeClosed) public onlyOwner {
		tvm.rawReserve(LimitOrderGas.SET_CODE, 0);
		limitOrderCodeClosed = _limitOrderCodeClosed;

		emit LimitOrderCodeClosedUpgraded();

		msg.sender.transfer(
			0,
			false,
			MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		);
	}

	function setlimitOrderCodePlatform(TvmCell _limitOrderPlatform) public onlyOwner {
		tvm.rawReserve(LimitOrderGas.SET_CODE, 0);
		limitOrderPlatform = _limitOrderPlatform;

		emit LimitOrderCodePlatformUpgraded();

		msg.sender.transfer(
			0,
			false,
			MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		);
	}

	function createLimitOrderRoot(address tokenRoot) override external view {
		require(
			msg.value >= LimitOrderGas.DEPLOY_ORDERS_ROOT,
			LimitOrderErrors.VALUE_TOO_LOW
		);
		tvm.rawReserve(LimitOrderGas.DEPLOY_ORDERS_ROOT, 0);

		TvmCell indexCode = buildCode(owner, tokenRoot, limitOrderRootCode);
		TvmCell stateInit_ = buildState(indexCode, tokenRoot);

		new LimitOrderRoot{
			stateInit: stateInit_,
			value: 0,
			flag: MsgFlag.ALL_NOT_RESERVED
		}(
			msg.sender,
			dexRoot,
			limitOrderCode,
			limitOrderCodeClosed,
			versionLimitOrderRoot
		);
	}

	function getExpectedAddressLimitOrderRoot(address tokenRoot)
		override
		external
		view
		responsible
		returns (address)
	{
		return { value: 0, bounce: false, flag: MsgFlag.REMAINING_GAS } expectedAddressLimitOrderRoot(tokenRoot);
	}

	function onLimitOrderRootDeployed(
		address _limitOrderRoot,
		address tokenRoot,
		address sendGasTo
	) external override {
		require(
			msg.sender.value != 0 && msg.sender == expectedAddressLimitOrderRoot(tokenRoot), 
			LimitOrderErrors.NOT_LIMIT_ORDER_ROOT
		);
		tvm.rawReserve(LimitOrderGas.TARGET_BALANCE, 0);
		
		emit CreateLimitOrderRoot(_limitOrderRoot, tokenRoot);
		
		sendGasTo.transfer({
			value: 0,
			flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS
		});
	}

	function expectedAddressLimitOrderRoot(address tokenRoot) internal view returns(address) {
		return address(tvm.hash(buildState(buildCode(owner, tokenRoot, limitOrderRootCode), tokenRoot)));
	}

	function buildCode(
		address _owner,
		address tokenRoot,
		TvmCell _limitOrderRootCode
	) internal pure returns (TvmCell) {
		TvmBuilder salt;
		salt.store(_owner);
		salt.store(tokenRoot);
		return tvm.setCodeSalt(_limitOrderRootCode, salt.toCell());
	}

	function buildState(TvmCell code_, address tokenRoot) internal pure returns (TvmCell) {
		return
			tvm.buildStateInit({
				contr: LimitOrderRoot,
				varInit: {
					spentTokenRoot: tokenRoot,
					limitOrderFactory: address(this)
				},
				code: code_
			});
	}

	function upgrade(
		TvmCell newCode,
		uint32 newVersion,
		address sendGasTo
	) external override onlyOwner {
		if (currentVersion == newVersion) {
			tvm.rawReserve(LimitOrderGas.TARGET_BALANCE, 0);
			sendGasTo.transfer({
				value: 0,
				flag: MsgFlag.ALL_NOT_RESERVED + MsgFlag.IGNORE_ERRORS,
				bounce: false
			});
		} else {
			emit LimitOrderFactoryUpgrade();

			TvmBuilder builder;
			builder.store(currentVersion);
			builder.store(newVersion);
			builder.store(versionLimitOrderRoot);

			builder.store(owner);
			builder.store(pendingOwner);
			builder.store(dexRoot);

			builder.store(limitOrderRootCode);
			builder.store(limitOrderCode);
			builder.store(limitOrderCodeClosed);
			//builder.store(limitOrderPlatform); //!!!

			// set code after complete this method
			tvm.setcode(newCode);

			// run onCodeUpgrade from new code
			tvm.setCurrentCode(newCode);

			onCodeUpgrade(builder.toCell());
		}
	}

	function onCodeUpgrade(TvmCell data) private {}
}
