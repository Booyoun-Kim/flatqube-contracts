pragma ton-solidity >= 0.57.0;

interface IAmplificationCoefficient {
    struct AmplificationCoefficient {
        uint128 value;
        uint128 precision;
    }
}
