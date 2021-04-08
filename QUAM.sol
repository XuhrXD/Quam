// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/GSN/Context.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // for WETH
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol"; // for WETH
import "@openzeppelin/contracts/access/Ownable.sol";

//token owner will be a time lock contract after farming started
contract QUAM is Context, Ownable, ERC20Burnable {
    using SafeMath for uint256;
    using Address for address;

    struct LockedToken {
        bool isUnlocked;
        uint256 unlockedTime;
        uint256 amount;
    }

    uint256 public constant MAX_SUPPLY = 100000000e18;

    uint256 public SEED_SALE_TOTAL = 5000000e18; //10%
    uint256 public PRIVATE_SALE_TOTAL = 15000000e18;
    uint256 public PUBLIC_SALE = 6400000e18;
    uint256 public LIQUIDITY = 1600000e18;
    uint256 public FARMING = 20000000e18;
    uint256 public MARKETING = 10000000e18;
    uint256 public TEAM = 10000000e18;
    uint256 public ADVISOR = 2000000e18;
    uint256 public DEVELOPMENT = 10000000e18;
    uint256 public ECOSYSTEM = 20000000e18;

    address public vault;

    uint256 public contractStartTimestamp;

    address public devFundAddress;
    uint256 public currentFarmRewards = 0;

    LockedToken[] public devMarketingTeamAdvisorFunds; //total 10 + 10 + +10 + 2
    LockedToken[] public seedAndPrivateSaleFunds; //5
    LockedToken[] public ecosystemFunds; //10

    constructor(address _dev) public ERC20("QUAMNETWORK.COM", "QUAM") {
        initialSetup(_dev);
    }

    function initialSetup(address _dev) internal {
        devFundAddress = _dev;
        _mint(address(this), MAX_SUPPLY);
        uint256 totalDevMarketingTeamAdvisor = MARKETING
            .add(TEAM)
            .add(ADVISOR)
            .add(DEVELOPMENT);

        uint256 unlockNow = (SEED_SALE_TOTAL.add(PRIVATE_SALE_TOTAL))
            .mul(20)
            .div(100);
        unlockNow = unlockNow.add(PUBLIC_SALE);
        unlockNow = unlockNow.add(LIQUIDITY);
        unlockNow = unlockNow.add(
            totalDevMarketingTeamAdvisor.mul(20).div(100)
        );

        contractStartTimestamp = block.timestamp;
        require(unlockNow == 18400000e18, "!unlock now");
        _transfer(address(this), devFundAddress, unlockNow);
        uint256 totalLock = 0;
        {
            //vesting devMarketingTeamAdvisorFunds


                uint256 devMarketingTeamAdvisorFundsVestingRemaining
             = totalDevMarketingTeamAdvisor.mul(80).div(100);

            //devMarketingTeamAdvisorFundsVestingRemaining vested 5 months
            uint256 perRelease = devMarketingTeamAdvisorFundsVestingRemaining
                .div(5);
            for (uint256 i = 0; i < 5; i++) {
                totalLock = totalLock.add(perRelease);
                devMarketingTeamAdvisorFunds.push(
                    LockedToken({
                        unlockedTime: block.timestamp + (i + 1).mul(30 days),
                        amount: perRelease,
                        isUnlocked: false
                    })
                );
            }
        }

        {
            //vesting seedSaleFunds

            uint256 seedAndPrivateSaleRemaining = (
                SEED_SALE_TOTAL.add(PRIVATE_SALE_TOTAL)
            )
                .mul(80)
                .div(100);

            //seedAndPrivateSaleRemaining vested 4 months
            uint256 perRelease = seedAndPrivateSaleRemaining.div(4);
            for (uint256 i = 0; i < 4; i++) {
                totalLock = totalLock.add(perRelease);

                seedAndPrivateSaleFunds.push(
                    LockedToken({
                        unlockedTime: block.timestamp + (i + 1).mul(30 days),
                        amount: perRelease,
                        isUnlocked: false
                    })
                );
            }
        }

        {
            //vesting ecosystemFund
            uint256 ecosystemFund = ECOSYSTEM;

            //ecosystemFund locked 6 months, then vested 6 months
            uint256 perRelease = ecosystemFund.div(6);
            for (uint256 i = 0; i < 5; i++) {
                totalLock = totalLock.add(perRelease);
                ecosystemFunds.push(
                    LockedToken({
                        unlockedTime: block.timestamp +
                            6 *
                            30 *
                            86400 +
                            i.mul(30 days),
                        amount: perRelease,
                        isUnlocked: false
                    })
                );
            }

            totalLock = totalLock.add(ecosystemFund.sub(5 * perRelease));
            ecosystemFunds.push(
                LockedToken({
                    unlockedTime: block.timestamp +
                        6 *
                        30 *
                        86400 +
                        uint256(5).mul(30 days),
                    amount: ecosystemFund.sub(5 * perRelease),
                    isUnlocked: false
                })
            );
        }

        require(
            totalLock.add(FARMING) == balanceOf(address(this)),
            "!total lock"
        );
    }

    function pendingDevMarketingTeamAdvisor() public view returns (uint256) {
        if (contractStartTimestamp == 0) return 0;
        uint256 ret = 0;
        for (uint256 i = 0; i < devMarketingTeamAdvisorFunds.length; i++) {
            if (devMarketingTeamAdvisorFunds[i].unlockedTime > block.timestamp)
                break;
            if (!devMarketingTeamAdvisorFunds[i].isUnlocked) {
                ret = ret.add(devMarketingTeamAdvisorFunds[i].amount);
            }
        }
        return ret;
    }

    function unlockDevMarketingTeamAdvisor() public {
        for (uint256 i = 0; i < devMarketingTeamAdvisorFunds.length; i++) {
            if (devMarketingTeamAdvisorFunds[i].unlockedTime > block.timestamp)
                break;
            if (!devMarketingTeamAdvisorFunds[i].isUnlocked) {
                devMarketingTeamAdvisorFunds[i].isUnlocked = true;
                _transfer(
                    address(this),
                    devFundAddress,
                    devMarketingTeamAdvisorFunds[i].amount
                );
            }
        }
    }

    function pendingTokenSale() public view returns (uint256) {
        if (contractStartTimestamp == 0) return 0;
        uint256 ret = 0;
        for (uint256 i = 0; i < seedAndPrivateSaleFunds.length; i++) {
            if (seedAndPrivateSaleFunds[i].unlockedTime > block.timestamp)
                break;
            if (!seedAndPrivateSaleFunds[i].isUnlocked) {
                ret = ret.add(seedAndPrivateSaleFunds[i].amount);
            }
        }
        return ret;
    }

    function unlockTokenSale() public {
        for (uint256 i = 0; i < seedAndPrivateSaleFunds.length; i++) {
            if (seedAndPrivateSaleFunds[i].unlockedTime > block.timestamp)
                break;
            if (!seedAndPrivateSaleFunds[i].isUnlocked) {
                seedAndPrivateSaleFunds[i].isUnlocked = true;
                _transfer(
                    address(this),
                    devFundAddress,
                    seedAndPrivateSaleFunds[i].amount
                );
            }
        }
    }

    function pendingEcosystem() public view returns (uint256) {
        if (contractStartTimestamp == 0) return 0;
        uint256 ret = 0;
        for (uint256 i = 0; i < ecosystemFunds.length; i++) {
            if (ecosystemFunds[i].unlockedTime > block.timestamp) break;
            if (!ecosystemFunds[i].isUnlocked) {
                ret = ret.add(ecosystemFunds[i].amount);
            }
        }
        return ret;
    }

    function unlockEcosystem() public {
        for (uint256 i = 0; i < ecosystemFunds.length; i++) {
            if (ecosystemFunds[i].unlockedTime > block.timestamp) break;
            if (!ecosystemFunds[i].isUnlocked) {
                ecosystemFunds[i].isUnlocked = true;
                _transfer(
                    address(this),
                    devFundAddress,
                    ecosystemFunds[i].amount
                );
            }
        }
    }

    function setDevFundReciever(address _devaddr) public onlyOwner {
        devFundAddress = _devaddr;
    }

    function setVault(address _v) public onlyOwner {
        vault = _v;
    }

    function getFarmRewards(uint256 _amount) public {
        require(msg.sender == vault, "!vault");
        if (currentFarmRewards >= FARMING) return;
        uint256 _transferAmount = _amount;
        if (currentFarmRewards.add(_transferAmount) > FARMING) {
            _transferAmount = FARMING.sub(currentFarmRewards);
        }
        currentFarmRewards = currentFarmRewards.add(_transferAmount);
        _transfer(address(this), vault, _transferAmount);
    }
}
