// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "../access/Ownable.sol";
import "../utils/EnumerableSet.sol";
import "../token/ERC20/IERC20.sol";
import "../token/ERC20/SafeERC20.sol";
import "../library/SafeMath.sol";
import "../interface/IKyi.sol";

interface IMasterChef {
    function pendingSushi(uint256 pid, address user) external view returns (uint256);

    function deposit(uint256 pid, uint256 amount) external;

    function withdraw(uint256 pid, uint256 amount) external;

    function emergencyWithdraw(uint256 pid) external;
}

contract CoinChef is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    using EnumerableSet for EnumerableSet.AddressSet;
    EnumerableSet.AddressSet private _sushiLP;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt.
        uint256 sushiRewardDebt; //sushi Reward debt.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. KYIs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that KYIs distribution occurs.
        uint256 accKyiPerShare; // Accumulated KYIs per share, times 1e12.
        uint256 totalAmount;    // Total amount of current pool deposit.
        uint256 accSushiPerShare; //Accumulated SuSHIs per share
    }

    // The KYI TOKEN!
    IKyi public kyi;
    // KYI tokens created per block.  每个区块可挖的sushi数量
    uint256 public constant kyiPerBlock = 100 * 1e18;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Corresponding to the pid of the sushi pool
    mapping(uint256 => uint256) public poolCorrespond;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when KYI mining starts.
    uint256 public startBlock;
    // The block number when KYI mining end;
    uint256 public endBlock;
    // SUSHI MasterChef 0xc2EdaD668740f1aA35E4D8f227fB8E17dcA888Cd
    address public constant sushiChef = 0xc2EdaD668740f1aA35E4D8f227fB8E17dcA888Cd;
    // SUSHI Token 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2
    address public constant sushiToken = 0x6B3595068778DD592e39A122f4f5a5cF09C90fE2;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        IKyi _kyi,
        uint256 _startBlock
    ) public {
        kyi = _kyi;
        startBlock = _startBlock;
        endBlock = _startBlock.add(200000);
    }

    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function addSushiLP(address _addLP) public onlyOwner returns (bool) {
        require(_addLP != address(0), "LP is the zero address");
        IERC20(_addLP).approve(sushiChef, uint256(- 1));
        return EnumerableSet.add(_sushiLP, _addLP);
    }

    function isSushiLP(address _LP) public view returns (bool) {
        return EnumerableSet.contains(_sushiLP, _LP);
    }

    function getSushiLPLength() public view returns (uint256) {
        return EnumerableSet.length(_sushiLP);
    }

    function getSushiLPAddress(uint256 _pid) public view returns (address){
        require(_pid <= getSushiLPLength() - 1, "not find this SushiLP");
        return EnumerableSet.at(_sushiLP, _pid);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        require(address(_lpToken) != address(0), "lpToken is the zero address");
        require(block.number < endBlock, "All token mining completed");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
        lpToken : _lpToken,
        allocPoint : _allocPoint,
        lastRewardBlock : lastRewardBlock,
        accKyiPerShare : 0,
        totalAmount : 0,
        accSushiPerShare : 0
        }));
    }

    // Update the given pool's KYI allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // The current pool corresponds to the pid of the sushi pool
    function setPoolCorr(uint256 _pid, uint256 _sid) public onlyOwner {
        require(_pid <= poolLength() - 1, "not find this pool");
        poolCorrespond[_pid] = _sid;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 number = block.number > endBlock ? endBlock : block.number;
        if (number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply;
        if (isSushiLP(address(pool.lpToken))) {
            if (pool.totalAmount == 0) {
                pool.lastRewardBlock = number;
                return;
            }
            lpSupply = pool.totalAmount;
        } else {
            lpSupply = pool.lpToken.balanceOf(address(this));
            if (lpSupply == 0) {
                pool.lastRewardBlock = number;
                return;
            }
        }

        uint256 multiplier = number.sub(pool.lastRewardBlock);
        uint256 kyiReward = multiplier.mul(kyiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        bool minRet = kyi.mint(address(this), kyiReward);
        if (minRet) {
            pool.accKyiPerShare = pool.accKyiPerShare.add(kyiReward.mul(1e12).div(lpSupply));
        }
        pool.lastRewardBlock = number;
    }

    // View function to see pending KYIs on frontend.
    function pending(uint256 _pid, address _user) external view returns (uint256, uint256){
        PoolInfo storage pool = poolInfo[_pid];
        if (isSushiLP(address(pool.lpToken))) {
            (uint256 kyiAmount, uint256 sushiAmount) = pendingKyiAndSushi(_pid, _user);
            return (kyiAmount, sushiAmount);
        } else {
            uint256 kyiAmount = pendingKyi(_pid, _user);
            return (kyiAmount, 0);
        }
    }

    function pendingKyiAndSushi(uint256 _pid, address _user) private view returns (uint256, uint256){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accKyiPerShare = pool.accKyiPerShare;
        uint256 accSushiPerShare = pool.accSushiPerShare;
        uint256 number = block.number > endBlock ? endBlock : block.number;
        if (user.amount > 0) {
            uint256 sushiPending = IMasterChef(sushiChef).pendingSushi(poolCorrespond[_pid], address(this));
            accSushiPerShare = accSushiPerShare.add(sushiPending.mul(1e12).div(pool.totalAmount));
            uint256 userPending = user.amount.mul(accSushiPerShare).div(1e12).sub(user.sushiRewardDebt);
            if (number > pool.lastRewardBlock) {
                uint256 multiplier = number.sub(pool.lastRewardBlock);
                uint256 kyiReward = multiplier.mul(kyiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
                accKyiPerShare = accKyiPerShare.add(kyiReward.mul(1e12).div(pool.totalAmount));
                return (user.amount.mul(accKyiPerShare).div(1e12).sub(user.rewardDebt), userPending);
            }
            if (number == pool.lastRewardBlock) {
                return (user.amount.mul(accKyiPerShare).div(1e12).sub(user.rewardDebt), userPending);
            }
        }
        return (0, 0);
    }

    function pendingKyi(uint256 _pid, address _user) private view returns (uint256){
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accKyiPerShare = pool.accKyiPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 number = block.number > endBlock ? endBlock : block.number;
        if (user.amount > 0) {
            if (number > pool.lastRewardBlock) {
                uint256 multiplier = block.number.sub(pool.lastRewardBlock);
                uint256 kyiReward = multiplier.mul(kyiPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
                accKyiPerShare = accKyiPerShare.add(kyiReward.mul(1e12).div(lpSupply));
                return user.amount.mul(accKyiPerShare).div(1e12).sub(user.rewardDebt);
            }
            if (number == pool.lastRewardBlock) {
                return user.amount.mul(accKyiPerShare).div(1e12).sub(user.rewardDebt);
            }
        }
        return 0;
    }

    // Deposit LP tokens to CoinChef for KYI allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (isSushiLP(address(pool.lpToken))) {
            depositKyiAndSushi(_pid, _amount, msg.sender);
        } else {
            depositKyi(_pid, _amount, msg.sender);
        }
    }

    function depositKyiAndSushi(uint256 _pid, uint256 _amount, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pendingAmount = user.amount.mul(pool.accKyiPerShare).div(1e12).sub(user.rewardDebt);
            if (pendingAmount > 0) {
                safeKyiTransfer(_user, pendingAmount);
            }
            uint256 beforeSushi = IERC20(sushiToken).balanceOf(address(this));
            IMasterChef(sushiChef).deposit(poolCorrespond[_pid], 0);
            uint256 afterSushi = IERC20(sushiToken).balanceOf(address(this));
            pool.accSushiPerShare = pool.accSushiPerShare.add(afterSushi.sub(beforeSushi).mul(1e12).div(pool.totalAmount));
            uint256 sushiPending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.sushiRewardDebt);
            if (sushiPending > 0) {
                IERC20(sushiToken).safeTransfer(_user, sushiPending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(_user, address(this), _amount);
            if (pool.totalAmount == 0) {
                IMasterChef(sushiChef).deposit(poolCorrespond[_pid], _amount);
                pool.totalAmount = pool.totalAmount.add(_amount);
                user.amount = user.amount.add(_amount);
            } else {
                uint256 beforeSushi = IERC20(sushiToken).balanceOf(address(this));
                IMasterChef(sushiChef).deposit(poolCorrespond[_pid], _amount);
                uint256 afterSushi = IERC20(sushiToken).balanceOf(address(this));
                pool.accSushiPerShare = pool.accSushiPerShare.add(afterSushi.sub(beforeSushi).mul(1e12).div(pool.totalAmount));
                pool.totalAmount = pool.totalAmount.add(_amount);
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accKyiPerShare).div(1e12);
        user.sushiRewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }

    function depositKyi(uint256 _pid, uint256 _amount, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pendingAmount = user.amount.mul(pool.accKyiPerShare).div(1e12).sub(user.rewardDebt);
            if (pendingAmount > 0) {
                safeKyiTransfer(_user, pendingAmount);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(_user, address(this), _amount);
            user.amount = user.amount.add(_amount);
            pool.totalAmount = pool.totalAmount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKyiPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }

    // Withdraw LP tokens from CoinChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (isSushiLP(address(pool.lpToken))) {
            withdrawKyiAndSushi(_pid, _amount, msg.sender);
        } else {
            withdrawKyi(_pid, _amount, msg.sender);
        }
    }

    function withdrawKyiAndSushi(uint256 _pid, uint256 _amount, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        require(user.amount >= _amount, "withdrawKyiAndSushi: not good");
        updatePool(_pid);
        uint256 pendingAmount = user.amount.mul(pool.accKyiPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingAmount > 0) {
            safeKyiTransfer(_user, pendingAmount);
        }
        if (_amount > 0) {
            uint256 beforeSushi = IERC20(sushiToken).balanceOf(address(this));
            IMasterChef(sushiChef).withdraw(poolCorrespond[_pid], _amount);
            uint256 afterSushi = IERC20(sushiToken).balanceOf(address(this));
            pool.accSushiPerShare = pool.accSushiPerShare.add(afterSushi.sub(beforeSushi).mul(1e12).div(pool.totalAmount));
            uint256 sushiPending = user.amount.mul(pool.accSushiPerShare).div(1e12).sub(user.sushiRewardDebt);
            if (sushiPending > 0) {
                IERC20(sushiToken).safeTransfer(_user, sushiPending);
            }
            user.amount = user.amount.sub(_amount);
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.lpToken.safeTransfer(_user, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKyiPerShare).div(1e12);
        user.sushiRewardDebt = user.amount.mul(pool.accSushiPerShare).div(1e12);
        emit Withdraw(_user, _pid, _amount);
    }

    function withdrawKyi(uint256 _pid, uint256 _amount, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        require(user.amount >= _amount, "withdrawKyi: not good");
        updatePool(_pid);
        uint256 pendingAmount = user.amount.mul(pool.accKyiPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingAmount > 0) {
            safeKyiTransfer(_user, pendingAmount);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalAmount = pool.totalAmount.sub(_amount);
            pool.lpToken.safeTransfer(_user, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accKyiPerShare).div(1e12);
        emit Withdraw(_user, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (isSushiLP(address(pool.lpToken))) {
            emergencyWithdrawKyiAndSushi(_pid, msg.sender);
        } else {
            emergencyWithdrawKyi(_pid, msg.sender);
        }
    }

    function emergencyWithdrawKyiAndSushi(uint256 _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 amount = user.amount;
        uint256 beforeSushi = IERC20(sushiToken).balanceOf(address(this));
        IMasterChef(sushiChef).withdraw(poolCorrespond[_pid], amount);
        uint256 afterSushi = IERC20(sushiToken).balanceOf(address(this));
        pool.accSushiPerShare = pool.accSushiPerShare.add(afterSushi.sub(beforeSushi).mul(1e12).div(pool.totalAmount));
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(_user, amount);
        pool.totalAmount = pool.totalAmount.sub(amount);
        emit EmergencyWithdraw(_user, _pid, amount);
    }

    function emergencyWithdrawKyi(uint256 _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(_user, amount);
        pool.totalAmount = pool.totalAmount.sub(amount);
        emit EmergencyWithdraw(_user, _pid, amount);
    }

    // Safe KYI transfer function, just in case if rounding error causes pool to not have enough KYIs.
    function safeKyiTransfer(address _to, uint256 _amount) internal {
        uint256 kyiBal = kyi.balanceOf(address(this));
        if (_amount > kyiBal) {
            kyi.transfer(_to, kyiBal);
        } else {
            kyi.transfer(_to, _amount);
        }
    }

}