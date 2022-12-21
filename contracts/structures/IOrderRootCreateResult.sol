pragma ton-solidity >= 0.62.0;

interface IOrderRootCreateResult {
    struct OrderRootCreateResult {
        address factory;
        address spentToken;
        uint32 oldVersion;
        uint32 newVersion;
        address deployer;
    }
}