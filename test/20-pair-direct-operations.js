const {expect} = require('chai');
const {
    Migration, afterRun, Constants, TOKEN_CONTRACTS_PATH, displayTx, expectedDepositLiquidity
} = require(process.cwd() + '/scripts/utils');
const BigNumber = require('bignumber.js');
const {Command} = require('commander');
const program = new Command();
BigNumber.config({EXPONENTIAL_AT: 257});
const logger = require('mocha-logger');

let tx;

const migration = new Migration();

program
    .allowUnknownOption()
    .option('-cn, --contract_name <contract_name>', 'DexPair contract name');

program.parse(process.argv);

const options = program.opts();

options.contract_name = options.contract_name || 'DexPair';

let DexRoot
let DexVault;
let DexPairFooBar;
let FooVaultWallet;
let BarVaultWallet;
let FooBarLpVaultWallet;
let FooPairWallet;
let BarPairWallet;
let FooBarLpPairWallet;
let FooRoot;
let BarRoot;
let FooBarLpRoot;
let Account3;
let FooWallet3;
let BarWallet3;
let FooBarLpWallet3;

const EMPTY_TVM_CELL = 'te6ccgEBAQEAAgAAAA==';

let IS_FOO_LEFT;

let keyPairs;

async function dexBalances() {
    const foo = await FooVaultWallet.call({method: 'balance', params: {}}).then(n => {
        return new BigNumber(n).shiftedBy(-Constants.tokens.foo.decimals).toString();
    });
    const bar = await BarVaultWallet.call({method: 'balance', params: {}}).then(n => {
        return new BigNumber(n).shiftedBy(-Constants.tokens.bar.decimals).toString();
    });
    const lp = await FooBarLpVaultWallet.call({method: 'balance', params: {}}).then(n => {
        return new BigNumber(n).shiftedBy(-Constants.LP_DECIMALS).toString();
    });
    return {foo, bar, lp};
}

async function account3balances() {
    let foo;
    await FooWallet3.call({method: 'balance', params: {}}).then(n => {
        foo = new BigNumber(n).shiftedBy(-Constants.tokens.foo.decimals).toString();
    }).catch(e => {/*ignored*/
    });
    let bar;
    await BarWallet3.call({method: 'balance', params: {}}).then(n => {
        bar = new BigNumber(n).shiftedBy(-Constants.tokens.bar.decimals).toString();
    }).catch(e => {/*ignored*/
    });
    let lp;
    await FooBarLpWallet3.call({method: 'balance', params: {}}).then(n => {
        lp = new BigNumber(n).shiftedBy(-Constants.LP_DECIMALS).toString();
    }).catch(e => {/*ignored*/
    });
    const ton = await locklift.utils.convertCrystal((await locklift.ton.getBalance(Account3.address)), 'ton').toNumber();
    return {foo, bar, lp, ton};
}

async function dexPairInfo() {
    const balances = await DexPairFooBar.call({method: 'getBalances', params: {}});
    const total_supply = await FooBarLpRoot.call({method: 'totalSupply', params: {}});
    let foo, bar;
    if (IS_FOO_LEFT) {
        foo = new BigNumber(balances.left_balance).shiftedBy(-Constants.tokens.foo.decimals).toString();
        bar = new BigNumber(balances.right_balance).shiftedBy(-Constants.tokens.bar.decimals).toString();
    } else {
        foo = new BigNumber(balances.right_balance).shiftedBy(-Constants.tokens.foo.decimals).toString();
        bar = new BigNumber(balances.left_balance).shiftedBy(-Constants.tokens.bar.decimals).toString();
    }

    return {
        foo: foo,
        bar: bar,
        lp_supply: new BigNumber(balances.lp_supply).shiftedBy(-Constants.LP_DECIMALS).toString(),
        lp_supply_actual: new BigNumber(total_supply).shiftedBy(-Constants.LP_DECIMALS).toString()
    };
}

function logBalances(header, dex, account, pair) {
    logger.log(`DEX balance ${header}: ${dex.foo} FOO, ${dex.bar} BAR, ${dex.lp} LP`);
    logger.log(`DexPair ${header}: ` +
        `${pair.foo} FOO, ${pair.bar} BAR, ` +
        `LP SUPPLY (PLAN): ${pair.lp_supply || "0"} LP, ` +
        `LP SUPPLY (ACTUAL): ${pair.lp_supply_actual || "0"} LP`);
    logger.log(`Account#3 balance ${header}: ` +
        `${account.foo !== undefined ? account.foo + ' FOO' : 'FOO (not deployed)'}, ` +
        `${account.bar !== undefined ? account.bar + ' BAR' : 'BAR (not deployed)'}, ` +
        `${account.lp !== undefined ? account.lp + ' LP' : 'LP (not deployed)'}`);
}

describe('Check direct DexPairFooBar operations', async function () {
    this.timeout(Constants.TESTS_TIMEOUT);
    before('Load contracts', async function () {
        keyPairs = await locklift.keys.getKeyPairs();

        DexRoot = await locklift.factory.getContract('DexRoot');
        DexVault = await locklift.factory.getContract('DexVault');
        DexPairFooBar = await locklift.factory.getContract(options.contract_name);
        FooRoot = await locklift.factory.getContract('TokenRootUpgradeable', TOKEN_CONTRACTS_PATH);
        BarRoot = await locklift.factory.getContract('TokenRootUpgradeable', TOKEN_CONTRACTS_PATH);
        FooBarLpRoot = await locklift.factory.getContract('TokenRootUpgradeable', TOKEN_CONTRACTS_PATH);
        FooVaultWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        BarVaultWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        FooBarLpVaultWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        FooPairWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        BarPairWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        FooBarLpPairWallet = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        Account3 = await locklift.factory.getAccount('Wallet');
        Account3.afterRun = afterRun;
        FooWallet3 = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        BarWallet3 = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);
        FooBarLpWallet3 = await locklift.factory.getContract('TokenWalletUpgradeable', TOKEN_CONTRACTS_PATH);

        migration.load(DexRoot, 'DexRoot');
        migration.load(DexVault, 'DexVault');
        migration.load(DexPairFooBar, 'DexPoolFooBar');
        migration.load(FooVaultWallet, 'FooVaultWallet');
        migration.load(BarVaultWallet, 'BarVaultWallet');
        migration.load(FooBarLpVaultWallet, 'FooBarLpVaultWallet');
        migration.load(FooPairWallet, 'FooBarPool_FooWallet');
        migration.load(BarPairWallet, 'FooBarPool_BarWallet');
        migration.load(FooBarLpPairWallet, 'FooBarPool_LpWallet');
        migration.load(FooRoot, 'FooRoot');
        migration.load(BarRoot, 'BarRoot');
        migration.load(FooBarLpRoot, 'FooBarLpRoot');
        migration.load(Account3, 'Account3');
        migration.load(FooWallet3, 'FooWallet3');

        if (migration.exists('BarWallet3')) {
            migration.load(BarWallet3, 'BarWallet3');
            logger.log(`BarWallet#3: ${BarWallet3.address}`);
        } else {
            const expected = await BarRoot.call({
                method: 'walletOf',
                params: {
                    walletOwner: Account3.address
                }
            });
            logger.log(`BarWallet#3: ${expected} (not deployed)`);
        }
        if (migration.exists('FooBarLpWallet3')) {
            migration.load(FooBarLpWallet3, 'FooBarLpWallet3');
            logger.log(`FooBarLpWallet3#3: ${FooBarLpWallet3.address}`);
        } else {
            const expected = await FooBarLpRoot.call({
                method: 'walletOf',
                params: {
                    walletOwner: Account3.address
                }
            });
            logger.log(`FooBarLpWallet#3: ${expected} (not deployed)`);
        }
        const pairRoots = await DexPairFooBar.call({method: 'getTokenRoots', params: {}});
        IS_FOO_LEFT = pairRoots.left === FooRoot.address;

        logger.log(`Vault wallets: 
            FOO: ${FooVaultWallet.address}
            BAR: ${BarVaultWallet.address}
            LP: ${FooBarLpVaultWallet.address}
        `);

        logger.log(`Pair wallets: 
            FOO: ${FooPairWallet.address}
            BAR: ${BarPairWallet.address}
            LP: ${FooBarLpPairWallet.address}
        `);

        logger.log('DexRoot: ' + DexRoot.address);
        logger.log('DexVault: ' + DexVault.address);
        logger.log('DexPairFooBar: ' + DexPairFooBar.address);
        logger.log('FooRoot: ' + FooRoot.address);
        logger.log('BarRoot: ' + BarRoot.address);
        logger.log('Account#3: ' + Account3.address);
        logger.log('FooWallet#3: ' + FooWallet3.address);

        logger.log('IS_FOO_LEFT: ' + IS_FOO_LEFT);

        await migration.balancesCheckpoint();
    });

    describe('Direct exchange (positive)', async function () {
        it('0010 # Account#3 exchange FOO to BAR (with deploy BarWallet#3)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange FOO to BAR (with deploy BarWallet#3)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_EXCHANGE = 1000;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    spent_token_root: FooRoot.address
                }
            });

            logger.log(`Spent amount: ${TOKENS_TO_EXCHANGE} FOO`);
            logger.log(`Expected fee: ${new BigNumber(expected.expected_fee).shiftedBy(-Constants.tokens.foo.decimals).toString()} FOO`);
            logger.log(`Expected receive amount: ${new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: locklift.utils.convertCrystal('0.05', 'nano'),
                    expected_amount: expected.expected_amount
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            BarWallet3.setAddress(await BarRoot.call({
                method: 'walletOf',
                params: {
                    walletOwner: Account3.address
                }
            }));

            migration.store(BarWallet3, 'BarWallet3');

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo).plus(TOKENS_TO_EXCHANGE).toString();
            const expectedDexBar = new BigNumber(dexStart.bar)
                .minus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo).minus(TOKENS_TO_EXCHANGE).toString();
            const expectedAccountBar = new BigNumber(accountStart.bar || 0)
                .plus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();

            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
        });

        it('0020 # Account#3 exchange BAR to FOO', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange BAR to FOO');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_EXCHANGE = 100;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.bar.decimals).toString(),
                    spent_token_root: BarRoot.address
                }
            });

            logger.log(`Spent amount: ${TOKENS_TO_EXCHANGE.toString()} BAR`);
            logger.log(`Expected fee: ${new BigNumber(expected.expected_fee).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);
            logger.log(`Expected receive amount: ${new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.foo.decimals).toString()} FOO`);

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0,
                    expected_amount: expected.expected_amount
                }
            });

            tx = await Account3.runTarget({
                contract: BarWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.bar.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo)
                .minus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.foo.decimals)).toString();
            const expectedDexBar = new BigNumber(dexStart.bar).plus(TOKENS_TO_EXCHANGE).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo)
                .plus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.foo.decimals)).toString();
            const expectedAccountBar = new BigNumber(accountStart.bar).minus(TOKENS_TO_EXCHANGE).toString();

            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
        });

        it('0030 # Account#3 exchange BAR to FOO (expectedSpendAmount)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange BAR to FOO');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_RECEIVE = 1;

            const expected = await DexPairFooBar.call({
                method: 'expectedSpendAmount', params: {
                    receive_amount: new BigNumber(TOKENS_TO_RECEIVE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    receive_token_root: FooRoot.address
                }
            });

            logger.log(`Expected spend amount: ${new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);
            logger.log(`Expected fee: ${new BigNumber(expected.expected_fee).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);
            logger.log(`Expected receive amount: ${TOKENS_TO_RECEIVE} FOO`);

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0,
                    expected_amount: 0
                }
            });

            tx = await Account3.runTarget({
                contract: BarWallet3,
                method: 'transfer',
                params: {
                    amount: expected.expected_amount,
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo)
                .minus(TOKENS_TO_RECEIVE).toString();
            const expectedDexBar = new BigNumber(dexStart.bar)
                .plus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo)
                .plus(TOKENS_TO_RECEIVE).toString();
            const expectedAccountBar = new BigNumber(accountStart.bar)
                .minus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();

            // expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
        });

        it('0040 # Account#3 exchange FOO to BAR (small amount)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange FOO to BAR (small amount)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const AMOUNT = 100;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: AMOUNT,
                    spent_token_root: FooRoot.address
                }
            });

            logger.log(`Expected fee: ${new BigNumber(expected.expected_fee).shiftedBy(-Constants.tokens.foo.decimals).toString()} FOO`);
            logger.log(`Expected receive amount: ${new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0,
                    expected_amount: 0
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: AMOUNT,
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.6', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexBar = new BigNumber(dexStart.bar)
                .minus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();
            const expectedDexFoo = new BigNumber(dexStart.foo).plus(new BigNumber(AMOUNT).shiftedBy(-Constants.tokens.foo.decimals)).toString();
            const expectedAccountBar = new BigNumber(accountStart.bar)
                .plus(new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals)).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo).minus(new BigNumber(AMOUNT).shiftedBy(-Constants.tokens.foo.decimals)).toString();

            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
        });
    });

    describe('Direct deposit liquidity (positive)', async function () {

        it('0050 # Account#3 deposit FOO liquidity (small amount)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 deposit FOO liquidity (small amount)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const LP_REWARD = await expectedDepositLiquidity(
                DexPairFooBar.address,
                options.contract_name,
                IS_FOO_LEFT ? [Constants.tokens.foo, Constants.tokens.bar] : [Constants.tokens.bar, Constants.tokens.foo],
                IS_FOO_LEFT ? [1000, 0] : [0, 1000],
                true
            );

            const payload = await DexPairFooBar.call({
                method: 'buildDepositLiquidityPayload', params: {
                    id: 0,
                    deploy_wallet_grams: locklift.utils.convertCrystal('0.05', 'nano')
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: 1000,
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            })

            displayTx(tx);

            FooBarLpWallet3.setAddress(await FooBarLpRoot.call({
                method: 'walletOf',
                params: {
                    walletOwner: Account3.address
                }
            }));

            migration.store(FooBarLpWallet3, 'FooBarLpWallet3');

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo).plus(new BigNumber(1000).shiftedBy(-Constants.tokens.foo.decimals)).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo).minus(new BigNumber(1000).shiftedBy(-Constants.tokens.foo.decimals)).toString();
            const expectedAccountLp = new BigNumber(accountStart.lp || 0).plus(LP_REWARD).toString();

            expect(pairEnd.lp_supply_actual).to.equal(pairEnd.lp_supply, 'Wrong LP supply');
            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountLp).to.equal(accountEnd.lp.toString(), 'Wrong Account#3 LP balance');
        });

        it('0060 # Account#3 deposit FOO liquidity', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 deposit FOO liquidity');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_DEPOSIT = 100;

            const LP_REWARD = await expectedDepositLiquidity(
                DexPairFooBar.address,
                options.contract_name,
                IS_FOO_LEFT ? [Constants.tokens.foo, Constants.tokens.bar] : [Constants.tokens.bar, Constants.tokens.foo],
                IS_FOO_LEFT ?
                    [new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.foo.decimals).toString(), 0] :
                    [0, new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.foo.decimals).toString()],
                true
            );

            const payload = await DexPairFooBar.call({
                method: 'buildDepositLiquidityPayload', params: {
                    id: 0,
                    deploy_wallet_grams: locklift.utils.convertCrystal('0.05', 'nano')
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            FooBarLpWallet3.setAddress(await FooBarLpRoot.call({
                method: 'walletOf',
                params: {
                    walletOwner: Account3.address
                }
            }));

            migration.store(FooBarLpWallet3, 'FooBarLpWallet3');

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo).plus(TOKENS_TO_DEPOSIT).toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo).minus(TOKENS_TO_DEPOSIT).toString();
            const expectedAccountLp = new BigNumber(accountStart.lp || 0).plus(LP_REWARD).toString();

            expect(pairEnd.lp_supply_actual).to.equal(pairEnd.lp_supply, 'Wrong LP supply');
            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountLp).to.equal(accountEnd.lp.toString(), 'Wrong Account#3 LP balance');
        });

        it('0070 # Account#3 deposit BAR liquidity', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 deposit BAR liquidity');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_DEPOSIT = 100;

            const LP_REWARD = await expectedDepositLiquidity(
                DexPairFooBar.address,
                options.contract_name,
                IS_FOO_LEFT ? [Constants.tokens.foo, Constants.tokens.bar] : [Constants.tokens.bar, Constants.tokens.foo],
                IS_FOO_LEFT ?
                    [0, new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.bar.decimals).toString()] :
                    [new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.bar.decimals).toString(), 0],
                true
            );

            const payload = await DexPairFooBar.call({
                method: 'buildDepositLiquidityPayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0
                }
            });

            tx = await Account3.runTarget({
                contract: BarWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_DEPOSIT).shiftedBy(Constants.tokens.bar.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexBar = new BigNumber(dexStart.bar).plus(TOKENS_TO_DEPOSIT).toString();
            const expectedAccountBar = new BigNumber(accountStart.bar).minus(TOKENS_TO_DEPOSIT).toString();
            const expectedAccountLp = new BigNumber(accountStart.lp).plus(LP_REWARD).toString();

            expect(pairEnd.lp_supply_actual).to.equal(pairEnd.lp_supply, 'Wrong LP supply');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
            expect(expectedAccountLp).to.equal(accountEnd.lp.toString(), 'Wrong Account#3 LP balance');
        });

    });

    describe('Direct withdraw liquidity (positive)', async function () {
        it('0080 # Account#3 direct withdraw liquidity (small amount)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 direct withdraw liquidity (small amount)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const expected = await DexPairFooBar.call({
                method: 'expectedWithdrawLiquidity', params: {
                    lp_amount: 1000
                }
            });

            const payload = await DexPairFooBar.call({
                method: 'buildWithdrawLiquidityPayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0
                }
            });

            let expectedFoo;
            let expectedBar;

            if (IS_FOO_LEFT) {
                expectedFoo = new BigNumber(expected.expected_left_amount)
                    .shiftedBy(-Constants.tokens.foo.decimals).toString();
                expectedBar = new BigNumber(expected.expected_right_amount)
                    .shiftedBy(-Constants.tokens.bar.decimals).toString();
            } else {
                expectedFoo = new BigNumber(expected.expected_right_amount)
                    .shiftedBy(-Constants.tokens.foo.decimals).toString();
                expectedBar = new BigNumber(expected.expected_left_amount)
                    .shiftedBy(-Constants.tokens.bar.decimals).toString();
            }

            logger.log(`Expected FOO: ${expectedFoo}`);
            logger.log(`Expected BAR: ${expectedBar}`);

            tx = await Account3.runTarget({
                contract: FooBarLpWallet3,
                method: 'transfer',
                params: {
                    amount: 1000,
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo)
                .minus(expectedFoo)
                .toString();
            const expectedDexBar = new BigNumber(dexStart.bar)
                .minus(expectedBar)
                .toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo)
                .plus(expectedFoo)
                .toString();
            const expectedAccountBar = new BigNumber(accountStart.bar)
                .plus(expectedBar)
                .toString();

            expect(pairEnd.lp_supply_actual).to.equal(pairEnd.lp_supply, 'Wrong LP supply');
            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
        });

        it('0090 # Account#3 direct withdraw liquidity', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 direct withdraw liquidity');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            let LP_AMOUNT = new BigNumber(accountStart.lp / 2).dp(Constants.LP_DECIMALS).toString();

            const expected = await DexPairFooBar.call({
                method: 'expectedWithdrawLiquidity', params: {
                    lp_amount: new BigNumber(LP_AMOUNT).shiftedBy(Constants.LP_DECIMALS).toString()
                }
            });

            const payload = await DexPairFooBar.call({
                method: 'buildWithdrawLiquidityPayload', params: {
                    id: 0,
                    deploy_wallet_grams: 0
                }
            });

            let expectedFoo;
            let expectedBar;

            if (IS_FOO_LEFT) {
                expectedFoo = new BigNumber(expected.expected_left_amount)
                    .shiftedBy(-Constants.tokens.foo.decimals).toString();
                expectedBar = new BigNumber(expected.expected_right_amount)
                    .shiftedBy(-Constants.tokens.bar.decimals).toString();
            } else {
                expectedFoo = new BigNumber(expected.expected_right_amount)
                    .shiftedBy(-Constants.tokens.foo.decimals).toString();
                expectedBar = new BigNumber(expected.expected_left_amount)
                    .shiftedBy(-Constants.tokens.bar.decimals).toString();
            }

            logger.log(`Expected FOO: ${expectedFoo}`);
            logger.log(`Expected BAR: ${expectedBar}`);

            tx = await Account3.runTarget({
                contract: FooBarLpWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(LP_AMOUNT).shiftedBy(Constants.LP_DECIMALS).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            const expectedDexFoo = new BigNumber(dexStart.foo)
                .minus(expectedFoo)
                .toString();
            const expectedDexBar = new BigNumber(dexStart.bar)
                .minus(expectedBar)
                .toString();
            const expectedAccountFoo = new BigNumber(accountStart.foo)
                .plus(expectedFoo)
                .toString();
            const expectedAccountBar = new BigNumber(accountStart.bar)
                .plus(expectedBar)
                .toString();
            const expectedAccountLp = new BigNumber(accountStart.lp).minus(LP_AMOUNT).toString();

            expect(pairEnd.lp_supply_actual).to.equal(pairEnd.lp_supply, 'Wrong LP supply');
            expect(expectedDexFoo).to.equal(dexEnd.foo.toString(), 'Wrong DEX FOO balance');
            expect(expectedDexBar).to.equal(dexEnd.bar.toString(), 'Wrong DEX BAR balance');
            expect(expectedAccountFoo).to.equal(accountEnd.foo.toString(), 'Wrong Account#3 FOO balance');
            expect(expectedAccountBar).to.equal(accountEnd.bar.toString(), 'Wrong Account#3 BAR balance');
            expect(expectedAccountLp).to.equal(accountEnd.lp.toString(), 'Wrong Account#3 LP balance');
        });
    });

    describe('Direct exchange (negative)', async function () {

        it('0100 # Account#3 exchange FOO to BAR (empty payload)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange FOO to BAR (empty payload)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_EXCHANGE = 100;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    spent_token_root: FooRoot.address
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: EMPTY_TVM_CELL
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            expect(dexStart.foo).to.equal(dexEnd.foo, 'Wrong DEX FOO balance');
            expect(dexStart.bar).to.equal(dexEnd.bar, 'Wrong DEX BAR balance');
            expect(accountStart.foo).to.equal(accountEnd.foo, 'Wrong Account#3 FOO balance');
            expect(accountStart.bar).to.equal(accountEnd.bar, 'Wrong Account#3 BAR balance');
        });

        it('0110 # Account#3 exchange FOO to BAR (low gas)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange FOO to BAR (low gas)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_EXCHANGE = 100;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    spent_token_root: FooRoot.address
                }
            });

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: locklift.utils.convertCrystal('0.05', 'nano'),
                    expected_amount: expected.expected_amount
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('1', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            expect(dexStart.foo).to.equal(dexEnd.foo, 'Wrong DEX FOO balance');
            expect(dexStart.bar).to.equal(dexEnd.bar, 'Wrong DEX BAR balance');
            expect(accountStart.foo).to.equal(accountEnd.foo, 'Wrong Account#3 FOO balance');
            expect(accountStart.bar).to.equal(accountEnd.bar, 'Wrong Account#3 BAR balance');
        });

        it('0120 # Account#3 exchange FOO to BAR (wrong rate)', async function () {
            logger.log('#################################################');
            logger.log('# Account#3 exchange FOO to BAR (wrong rate)');
            const dexStart = await dexBalances();
            const accountStart = await account3balances();
            const pairStart = await dexPairInfo();
            logBalances('start', dexStart, accountStart, pairStart);

            const TOKENS_TO_EXCHANGE = 100;

            const expected = await DexPairFooBar.call({
                method: 'expectedExchange', params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    spent_token_root: FooRoot.address
                }
            });

            logger.log(`Spent amount: ${TOKENS_TO_EXCHANGE} FOO`);
            logger.log(`Expected fee: ${new BigNumber(expected.expected_fee).shiftedBy(-Constants.tokens.foo.decimals).toString()} FOO`);
            logger.log(`Expected receive amount: ${new BigNumber(expected.expected_amount).shiftedBy(-Constants.tokens.bar.decimals).toString()} BAR`);

            const payload = await DexPairFooBar.call({
                method: 'buildExchangePayload', params: {
                    id: 0,
                    deploy_wallet_grams: locklift.utils.convertCrystal('0.05', 'nano'),
                    expected_amount: new BigNumber(expected.expected_amount).plus(1).toString()
                }
            });

            tx = await Account3.runTarget({
                contract: FooWallet3,
                method: 'transfer',
                params: {
                    amount: new BigNumber(TOKENS_TO_EXCHANGE).shiftedBy(Constants.tokens.foo.decimals).toString(),
                    recipient: DexPairFooBar.address,
                    deployWalletValue: 0,
                    remainingGasTo: Account3.address,
                    notify: true,
                    payload: payload
                },
                value: locklift.utils.convertCrystal('2.3', 'nano'),
                keyPair: keyPairs[2]
            });

            displayTx(tx);

            const dexEnd = await dexBalances();
            const accountEnd = await account3balances();
            const pairEnd = await dexPairInfo();
            logBalances('end', dexEnd, accountEnd, pairEnd);
            await migration.logGas();

            expect(dexStart.foo).to.equal(dexEnd.foo, 'Wrong DEX FOO balance');
            expect(dexStart.bar).to.equal(dexEnd.bar, 'Wrong DEX BAR balance');
            expect(accountStart.foo).to.equal(accountEnd.foo, 'Wrong Account#3 FOO balance');
            expect(accountStart.bar).to.equal(accountEnd.bar, 'Wrong Account#3 BAR balance');
        });
    });
});
