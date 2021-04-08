pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// Vault distributes fees equally amongst staked pools
// Have fun reading it. Hopefully it's bug-free. God bless.

interface IQUAM is IERC20 {
    function getFarmRewards(uint256 _amount) external;

    function currentFarmRewards() external view returns (uint256);

    function FARMING() external view returns (uint256);

    function burn(uint256 amount) external;
}

interface IFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IMigratorChef {
    function migrate(IERC20 token) external returns (IERC20);
}

abstract contract IPancakePair {
    address public token0;
    address public token1;
}

abstract contract IPancakeSwapRouter {
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external virtual returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual returns (uint[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual returns (uint amountA, uint amountB, uint liquidity);

    function WETH() external virtual returns (address);
    function factory() external virtual returns (address);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual payable returns (uint amountToken, uint amountETH, uint liquidity);
}

// MasterChef is the master of Quam. He can make Quam and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once QUAM is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of QUAM
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accQuamPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accQuamPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
        uint256 lockedReward;   //locked 75%, released gradually over next 30 days
        uint256 lastWithdrawalBlock;
        uint256 releasedLockedReward;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. QUAMs to distribute per block.
        uint256 lastRewardBlock; // Last block number that QUAMs distribution occurs.
        uint256 accQuamPerShare; // Accumulated QUAMs per share, times 1e12. See below.
        bool emergencyWithdrawnable;
        bool shouldBurn;    //dont burn if single staking asset
        bool shouldMarketBuy;
    }

    IQUAM public quam;
    // Dev address.
    address public devaddr;
    // Block number when bonus QUAM period ends.
    uint256 public bonusEndBlock;
    // QUAM tokens created per block.
    uint256 public quamPerBlock;
    uint256 public secondPerDay;
    // Bonus muliplier for early quam makers.
    uint256 public constant BONUS_MULTIPLIER = 6;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when QUAM mining starts.
    uint256 public startBlock;

    uint256 public totalQuamStaked;

    IPancakeSwapRouter public swapRouter = IPancakeSwapRouter(
        0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F
    );

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        address _quam,
        address _devaddr,
        uint256 _startBlock,
        uint256 _quamPerBlock,
        uint256 _secondPerDay,
        address _router
    ) public {
        quam = _quam == address(0)? IQUAM(0x1AdE17B4B38B472B5259BbC938618226dF7b5Ca8) : IQUAM(_quam);
        if (_router != address(0)) {
            swapRouter = IPancakeSwapRouter(_router);
        }
        devaddr = _devaddr;
        quamPerBlock = _quamPerBlock > 0? _quamPerBlock : 6e18;
        startBlock = _startBlock < block.number? block.number:_startBlock;
        secondPerDay = _secondPerDay > 0? _secondPerDay : 86400;
        bonusEndBlock = startBlock + 7 * secondPerDay/3;   //7 days for bonus rewards
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate,
        bool _shouldBurn,
        bool _shouldMarketBuy
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accQuamPerShare: 0,
                emergencyWithdrawnable: false,
                shouldBurn: _shouldBurn,
                shouldMarketBuy: _shouldMarketBuy
            })
        );
        IERC20(_lpToken).approve(address(swapRouter), uint256(-1));
    }

    function refreshApprove(uint256 _pid) public onlyOwner {
        IERC20 _lpToken = poolInfo[_pid].lpToken;
        _lpToken.approve(address(swapRouter), uint256(-1));
    }

    // Update the given pool's QUAM allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate,
        bool _shouldBurn,
        bool _shouldMarketBuy
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].shouldBurn = _shouldBurn;
        poolInfo[_pid].shouldMarketBuy = _shouldMarketBuy;
    }

    // // Set the migrator contract. Can only be called by the owner.
    // function setMigrator(IMigratorChef _migrator) public onlyOwner {
    //     migrator = _migrator;
    // }

    // // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    // function migrate(uint256 _pid) public {
    //     require(address(migrator) != address(0), "migrate: no migrator");
    //     PoolInfo storage pool = poolInfo[_pid];
    //     IERC20 lpToken = pool.lpToken;
    //     uint256 bal = lpToken.balanceOf(address(this));
    //     lpToken.safeApprove(address(migrator), bal);
    //     IERC20 newLpToken = migrator.migrate(lpToken);
    //     require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
    //     pool.lpToken = newLpToken;
    // }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending QUAMs on frontend.
    function pendingQuam(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accQuamPerShare = pool.accQuamPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (address(pool.lpToken) == address(quam)) {
            lpSupply = totalQuamStaked;
        }
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 quamReward = multiplier
                .mul(quamPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            if (quam.FARMING().sub(quam.currentFarmRewards()) <= quamReward) {
                quamReward = quam.FARMING().sub(quam.currentFarmRewards());
            }
            accQuamPerShare = accQuamPerShare.add(
                quamReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accQuamPerShare).div(1e12).sub(user.rewardDebt);
    }

    function pendingQuamNextBlock(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accQuamPerShare = pool.accQuamPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (address(pool.lpToken) == address(quam)) {
            lpSupply = totalQuamStaked;
        }
        if (block.number + 1 > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number + 1
            );
            uint256 quamReward = multiplier
                .mul(quamPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            if (quam.FARMING().sub(quam.currentFarmRewards()) <= quamReward) {
                quamReward = quam.FARMING().sub(quam.currentFarmRewards());
            }
            accQuamPerShare = accQuamPerShare.add(
                quamReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accQuamPerShare).div(1e12).sub(user.rewardDebt);
    }

    function setEmergencyWithdrawnable(uint256 _pid, bool _allowed)
        public
        onlyOwner
    {
        poolInfo[_pid].emergencyWithdrawnable = _allowed;
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (address(pool.lpToken) == address(quam)) {
            lpSupply = totalQuamStaked;
        }
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 quamReward = multiplier
            .mul(quamPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        uint256 quamRewardWithDev = quamReward.mul(11).div(10);
        uint256 balBefore = quam.balanceOf(address(this));
        quam.getFarmRewards(quamRewardWithDev);
        if (quam.currentFarmRewards() == quam.FARMING()) {
            quamRewardWithDev = quam.balanceOf(address(this)).sub(balBefore);
            quamReward = quamRewardWithDev.mul(10).div(11);
        }
        quam.transfer(devaddr, quamReward.div(10));
        pool.accQuamPerShare = pool.accQuamPerShare.add(
            quamReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for QUAM allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accQuamPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            lock(msg.sender, _pid, pending);
        }
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        if (address(pool.lpToken) == address(quam)) {
            totalQuamStaked = totalQuamStaked.add(_amount);
        } else {
            //check if deposit token is paired with bnb
            address wbnb = swapRouter.WETH();
            IFactory factory = IFactory(swapRouter.factory());
            if (factory.getPair(wbnb, address(pool.lpToken)) != address(0) && pool.shouldMarketBuy) {
                //buy bnb
                uint256 buyAmount = _amount.mul(10).div(100);
                _amount = _amount.mul(90).div(100);
                pool.lpToken.approve(address(swapRouter), uint256(-1));
                address[] memory path = new address[](2);
                path[0] = address(pool.lpToken);
                path[1] = wbnb;
                uint256 wbnbAmount = swapRouter.swapExactTokensForTokens(buyAmount, 0, path, address(this), block.timestamp + 100)[1];
                IERC20(wbnb).approve(address(swapRouter), uint256(-1));
                path[0] = wbnb;
                path[1] = address(quam);
                uint256 quamAmount = swapRouter.swapExactTokensForTokens(wbnbAmount.div(2), 0, path, address(this), block.timestamp + 100)[1];
                IERC20(address(quam)).approve(address(swapRouter), uint256(-1));
                uint256 snapshot = quam.balanceOf(address(this));
                swapRouter.addLiquidity(wbnb, address(quam), wbnbAmount.div(2), quamAmount, 0, 0, msg.sender, block.timestamp + 100);
                uint256 remainingQuam = quamAmount.sub(snapshot.sub(quam.balanceOf(address(this))));
                safeQuamTransfer(msg.sender, remainingQuam);
            } 
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accQuamPerShare).div(1e12);

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accQuamPerShare).div(1e12).sub(
            user.rewardDebt
        );
        lock(msg.sender, _pid, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accQuamPerShare).div(1e12);
        if (_amount > 0) {
            if (!pool.shouldBurn) {
                //dont burn if LP, only burn 2% if quam stake
                uint256 burnRate = 0;
                if (address(pool.lpToken) == address(quam)) {
                    totalQuamStaked = totalQuamStaked.sub(_amount);
                    burnRate = 2;
                } 
                if (burnRate > 0) {
                    pool.lpToken.safeTransfer(address(1), _amount.mul(burnRate).div(100));
                }
                pool.lpToken.safeTransfer(address(msg.sender), _amount.mul(100 - burnRate).div(100));
            } else {
                //lp token => burn
                uint256 burnt = _amount.div(5); //20%
                burnToken(_pid, msg.sender, burnt);
                pool.lpToken.safeTransfer(address(msg.sender), _amount.sub(burnt));
            }
        }
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function lock(address addr, uint256 _pid, uint256 pending) internal {
        UserInfo storage user = userInfo[_pid][addr];
        if (user.lastWithdrawalBlock < bonusEndBlock) {
            //lock 75% reward
            uint256 locked = pending.mul(75).div(100);
            user.lockedReward = user.lockedReward.add(locked);
            safeQuamTransfer(addr, pending.sub(locked));
        } else {
            safeQuamTransfer(addr, pending);
        }
        user.lastWithdrawalBlock = block.number;
        _unlockReward(_pid, addr);
    }

    function unlockableReward(uint256 _pid, address addr) public view returns (uint256 ret) {
        UserInfo storage user = userInfo[_pid][addr];
        uint256 blockPerWeek = 7 * secondPerDay/3;
        uint256 startUnlock = bonusEndBlock.add(2 * blockPerWeek);
        if (block.number > startUnlock) {
            if (user.releasedLockedReward != user.lockedReward) {
                uint256 totalLockedBlock = 30 * secondPerDay/3;//30 days
                uint256 distance = block.number.sub(startUnlock);
                uint256 shouldRelease = user.lockedReward.mul(distance).div(totalLockedBlock);
                if (shouldRelease > user.lockedReward) {
                    shouldRelease = user.lockedReward;
                }
                if (shouldRelease < user.releasedLockedReward) {
                    shouldRelease = 0;
                } else {
                    shouldRelease = shouldRelease.sub(user.releasedLockedReward);
                }
                ret = shouldRelease;
            }
        }
    }

    function unlockReward(uint256 _pid) public {
        _unlockReward(_pid, msg.sender);
    }

    function _unlockReward(uint256 _pid, address addr) internal {
        UserInfo storage user = userInfo[_pid][addr];
        uint256 blockPerWeek = 7 * secondPerDay/3;
        uint256 startUnlock = bonusEndBlock.add(2 * blockPerWeek);
        if (block.number > startUnlock) {
            if (user.releasedLockedReward != user.lockedReward) {
                uint256 totalLockedBlock = 30 * secondPerDay/3;//30 days
                uint256 distance = block.number.sub(startUnlock);
                uint256 shouldRelease = user.lockedReward.mul(distance).div(totalLockedBlock);
                if (shouldRelease > user.lockedReward) {
                    shouldRelease = user.lockedReward;
                }
                if (shouldRelease < user.releasedLockedReward) {
                    shouldRelease = 0;
                } else {
                    shouldRelease = shouldRelease.sub(user.releasedLockedReward);
                }
                user.releasedLockedReward = user.releasedLockedReward.add(shouldRelease);
                safeQuamTransfer(addr, shouldRelease);
            }
        }
    }

    function burnToken(
        uint256 _pid,
        address receiver,
        uint256 lpTokenAmount
    ) internal {
        IERC20 lpToken = poolInfo[_pid].lpToken;
        IPancakePair pancakePair = IPancakePair(address(lpToken));

        address token0 = pancakePair.token0();
        address token1 = pancakePair.token1();

        uint256 token0Received = IERC20(token0).balanceOf(address(this));
        uint256 token1Received = IERC20(token1).balanceOf(address(this));

        swapRouter.removeLiquidity(
            token0,
            token1,
            lpTokenAmount,
            1,
            1,
            address(this),
            block.timestamp + 100
        );

        token0Received = IERC20(token0).balanceOf(address(this)).sub(
            token0Received
        );
        token1Received = IERC20(token1).balanceOf(address(this)).sub(
            token1Received
        );

        address otherToken = address(0);
        uint256 otherTokenAmount = 0;

        if (token0 == address(quam)) {
            //burn withdrawn token
            quam.burn(token0Received);
            otherToken = token1;
            otherTokenAmount = token1Received;
        }

        if (token1 == address(quam)) {
            //burn withdrawn token
            quam.burn(token1Received);
            otherToken = token0;
            otherTokenAmount = token0Received;
        }

        if (otherToken != address(0) && otherTokenAmount > 0) {
            //market buy quam
            IERC20(otherToken).approve(address(swapRouter), otherTokenAmount);
            address[] memory path = new address[](2);
            path[0] = otherToken;
            path[1] = address(quam);
            swapRouter.swapExactTokensForTokens(otherTokenAmount, 0, path, receiver, block.timestamp + 100);
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        require(
            pool.emergencyWithdrawnable,
            "!emergencyWithdrawnable not allowed"
        );
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        if (address(pool.lpToken) == address(quam)) {
            totalQuamStaked = totalQuamStaked.sub(user.amount);
        }
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe quam transfer function, just in case if rounding error causes pool to not have enough QUAMs.
    function safeQuamTransfer(address _to, uint256 _amount) internal {
        uint256 quamBal = quam.balanceOf(address(this));
        if (_amount > quamBal) {
            quam.transfer(_to, quamBal);
        } else {
            quam.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
