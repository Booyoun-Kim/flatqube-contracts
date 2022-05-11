pragma ton-solidity >=0.57.0;

interface ILimitOrderClosed {
	struct LimitOrderClosedInitParams {
		address limitOrderRoot;
		address factoryOrderRoot;
		address ownerAddress;
		address spentTokenRoot;
		address receiveTokenRoot;
	}

	struct LimitOrderClosedDetails {
		address limitOrderRoot;
		address ownerAddress;
		uint64 swapAttempt;
		uint8 state;
		address spentTokenRoot;
		address receiveTokenRoot;
		address spentWallet;
		address receiveWallet;
		uint128 expectedAmount;
		uint128 initialAmount;
		uint128 currentAmountSpentToken;
	}

	function getCurrentStatus() external view responsible returns(uint8);

	function getInitParams() external view responsible returns(LimitOrderClosedInitParams);

	function getDetails() external view responsible returns(LimitOrderClosedDetails);
}
