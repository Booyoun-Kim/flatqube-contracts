pragma ton-solidity >= 0.57.0;

interface INextExchangeData {
    struct NextExchangeData {
        uint128 numerator;
        address poolRoot;
        TvmCell payload;
        uint32 msgValueNumerator;
    }
}
