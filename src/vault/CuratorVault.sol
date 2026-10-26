// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMeridian, MarketParams, Id, MarketParamsLib} from "../interfaces/IMeridian.sol";

/// @notice Target allocation for one market during a reallocation.
/// `assets` is the desired supply after the call; type(uint256).max means
/// "everything withdrawn so far that hasn't been re-supplied".
struct MarketAllocation {
    MarketParams params;
    uint256 assets;
}

/// @title CuratorVault
/// @notice ERC-4626 vault that lends one asset across several Meridian isolated
/// markets. Depositors pick a curator (risk manager), not individual markets.
///
/// Roles
///  - owner:     sets roles, fee, timelock
///  - curator:   sets per-market supply caps (raises are timelocked)
///  - allocator: orders supply/withdraw queues, reallocates liquidity
///  - guardian:  can veto pending cap raises / timelock cuts during the timelock
///
/// Safety model: any change that increases depositor risk (adding a market,
/// raising a cap, shortening the timelock) waits `timelock` seconds, so
/// depositors can exit before it lands. Risk-reducing changes are instant.
contract CuratorVault is ERC4626, Ownable {
    using Math for uint256;
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_FEE = 0.5e18;
    uint256 public constant MAX_QUEUE_LENGTH = 30;
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 14 days;

    struct MarketConfig {
        uint184 cap;
        bool enabled;
    }

    struct Pending {
        uint192 value;
        uint64 validAt;
    }

    IMeridian public immutable MERIDIAN;
    uint8 private immutable DECIMALS_OFFSET;

    address public curator;
    address public guardian;
    mapping(address => bool) public isAllocator;

    uint256 public timelock;
    Pending public pendingTimelock;

    uint96 public fee;
    address public feeRecipient;
    /// @dev Total assets as of the last fee accrual; interest above this is fee-able.
    uint256 public lastTotalAssets;

    mapping(Id => MarketConfig) public config;
    mapping(Id => Pending) public pendingCap;
    mapping(Id => MarketParams) internal _params;

    Id[] public supplyQueue;
    Id[] public withdrawQueue;

    event SetCurator(address curator);
    event SetGuardian(address guardian);
    event SetIsAllocator(address allocator, bool isAllocator);
    event SetFee(uint256 fee);
    event SetFeeRecipient(address feeRecipient);
    event SubmitTimelock(uint256 newTimelock);
    event SetTimelock(uint256 newTimelock);
    event SubmitCap(address indexed caller, Id indexed id, uint256 cap);
    event SetCap(address indexed caller, Id indexed id, uint256 cap);
    event RevokePendingCap(address indexed caller, Id indexed id);
    event SetSupplyQueue(address indexed caller, Id[] queue);
    event SetWithdrawQueue(address indexed caller, Id[] queue);
    event ReallocateSupply(address indexed caller, Id indexed id, uint256 assets);
    event ReallocateWithdraw(address indexed caller, Id indexed id, uint256 assets);
    event AccrueFee(uint256 newTotalAssets, uint256 feeShares);

    error NotCuratorRole();
    error NotAllocatorRole();
    error NotGuardianRole();
    error MaxFeeExceeded();
    error ZeroFeeRecipient();
    error InvalidTimelock();
    error NoPendingValue();
    error TimelockNotElapsed();
    error AlreadyPending();
    error AlreadySet();
    error InconsistentAsset();
    error MarketNotCreated();
    error UnauthorizedMarket(Id id);
    error SupplyCapExceeded(Id id);
    error MaxQueueLengthExceeded();
    error DuplicateMarket(Id id);
    error InvalidMarketRemoval(Id id);
    error NotEnoughLiquidity();

    constructor(
        address _owner,
        IMeridian meridian,
        uint256 initialTimelock,
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(_owner) {
        if (initialTimelock < MIN_TIMELOCK || initialTimelock > MAX_TIMELOCK) revert InvalidTimelock();
        MERIDIAN = meridian;
        timelock = initialTimelock;
        uint8 assetDecimals = IERC20Metadata(address(_asset)).decimals();
        DECIMALS_OFFSET = assetDecimals < 18 ? 18 - assetDecimals : 0;
        _asset.forceApprove(address(meridian), type(uint256).max);
    }

    /* ------------------------------------------------------------------ */
    /*                                 ROLES                              */
    /* ------------------------------------------------------------------ */

    modifier onlyCuratorRole() {
        if (msg.sender != curator && msg.sender != owner()) revert NotCuratorRole();
        _;
    }

    modifier onlyAllocatorRole() {
        if (!isAllocator[msg.sender] && msg.sender != curator && msg.sender != owner()) revert NotAllocatorRole();
        _;
    }

    modifier onlyGuardianRole() {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianRole();
        _;
    }

    function setCurator(address newCurator) external onlyOwner {
        curator = newCurator;
        emit SetCurator(newCurator);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit SetGuardian(newGuardian);
    }

    function setIsAllocator(address allocator, bool value) external onlyOwner {
        isAllocator[allocator] = value;
        emit SetIsAllocator(allocator, value);
    }

    function setFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert MaxFeeExceeded();
        if (newFee != 0 && feeRecipient == address(0)) revert ZeroFeeRecipient();
        _accrueFee(); // don't apply new fee retroactively
        fee = uint96(newFee);
        emit SetFee(newFee);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0) && fee != 0) revert ZeroFeeRecipient();
        _accrueFee();
        feeRecipient = newRecipient;
        emit SetFeeRecipient(newRecipient);
    }

    /* ------------------------------------------------------------------ */
    /*                                TIMELOCK                            */
    /* ------------------------------------------------------------------ */

    /// @notice Lengthening the timelock is instant; shortening it is itself timelocked.
    function submitTimelock(uint256 newTimelock) external onlyOwner {
        if (newTimelock < MIN_TIMELOCK || newTimelock > MAX_TIMELOCK) revert InvalidTimelock();
        if (newTimelock == timelock) revert AlreadySet();
        if (newTimelock > timelock) {
            timelock = newTimelock;
            delete pendingTimelock;
            emit SetTimelock(newTimelock);
        } else {
            pendingTimelock = Pending(uint192(newTimelock), uint64(block.timestamp + timelock));
            emit SubmitTimelock(newTimelock);
        }
    }

    function acceptTimelock() external {
        Pending memory p = pendingTimelock;
        if (p.validAt == 0) revert NoPendingValue();
        if (block.timestamp < p.validAt) revert TimelockNotElapsed();
        timelock = p.value;
        delete pendingTimelock;
        emit SetTimelock(p.value);
    }

    function revokePendingTimelock() external onlyGuardianRole {
        delete pendingTimelock;
    }

    /* ------------------------------------------------------------------ */
    /*                                  CAPS                              */
    /* ------------------------------------------------------------------ */

    function submitCap(MarketParams memory params, uint256 newCap) external onlyCuratorRole {
        Id id = params.id();
        if (params.loanToken != asset()) revert InconsistentAsset();
        (,,,, uint128 lastUpdate,) = MERIDIAN.market(id);
        if (lastUpdate == 0) revert MarketNotCreated();
        if (pendingCap[id].validAt != 0) revert AlreadyPending();

        uint256 currentCap = config[id].cap;
        if (newCap == currentCap) revert AlreadySet();

        if (newCap < currentCap) {
            _setCap(params, id, newCap);
        } else {
            pendingCap[id] = Pending(uint192(newCap), uint64(block.timestamp + timelock));
            _params[id] = params;
            emit SubmitCap(msg.sender, id, newCap);
        }
    }

    function acceptCap(MarketParams memory params) external {
        Id id = params.id();
        Pending memory p = pendingCap[id];
        if (p.validAt == 0) revert NoPendingValue();
        if (block.timestamp < p.validAt) revert TimelockNotElapsed();
        _setCap(params, id, p.value);
    }

    function revokePendingCap(Id id) external {
        if (msg.sender != guardian && msg.sender != curator && msg.sender != owner()) revert NotGuardianRole();
        delete pendingCap[id];
        emit RevokePendingCap(msg.sender, id);
    }

    function _setCap(MarketParams memory params, Id id, uint256 newCap) internal {
        MarketConfig storage c = config[id];
        if (newCap > 0 && !c.enabled) {
            if (withdrawQueue.length >= MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded();
            withdrawQueue.push(id);
            c.enabled = true;
            _params[id] = params;
            // Snapshot accrued fees before a new market starts contributing to totalAssets.
            _updateLastTotalAssets(lastTotalAssets + MERIDIAN.expectedSupplyAssets(params, address(this)));
        }
        c.cap = uint184(newCap);
        delete pendingCap[id];
        emit SetCap(msg.sender, id, newCap);
    }

    /* ------------------------------------------------------------------ */
    /*                                 QUEUES                             */
    /* ------------------------------------------------------------------ */

    function setSupplyQueue(Id[] calldata newQueue) external onlyAllocatorRole {
        if (newQueue.length > MAX_QUEUE_LENGTH) revert MaxQueueLengthExceeded();
        for (uint256 i; i < newQueue.length; ++i) {
            if (config[newQueue[i]].cap == 0) revert UnauthorizedMarket(newQueue[i]);
        }
        supplyQueue = newQueue;
        emit SetSupplyQueue(msg.sender, newQueue);
    }

    /// @notice Reorder / prune the withdraw queue. `indexes` are positions in the
    /// current queue. A market can only be dropped once its cap is 0 and the vault
    /// has no supply left in it (no stranded funds).
    function updateWithdrawQueue(uint256[] calldata indexes) external onlyAllocatorRole {
        uint256 currLength = withdrawQueue.length;
        bool[] memory seen = new bool[](currLength);
        Id[] memory newQueue = new Id[](indexes.length);

        for (uint256 i; i < indexes.length; ++i) {
            uint256 prevIndex = indexes[i];
            Id id = withdrawQueue[prevIndex];
            if (seen[prevIndex]) revert DuplicateMarket(id);
            seen[prevIndex] = true;
            newQueue[i] = id;
        }

        for (uint256 i; i < currLength; ++i) {
            if (!seen[i]) {
                Id id = withdrawQueue[i];
                if (config[id].cap != 0) revert InvalidMarketRemoval(id);
                if (pendingCap[id].validAt != 0) revert InvalidMarketRemoval(id);
                (uint256 supplyShares,,) = MERIDIAN.position(id, address(this));
                if (supplyShares != 0) revert InvalidMarketRemoval(id);
                delete config[id];
            }
        }

        withdrawQueue = newQueue;
        emit SetWithdrawQueue(msg.sender, newQueue);
    }

    function supplyQueueLength() external view returns (uint256) {
        return supplyQueue.length;
    }

    function withdrawQueueLength() external view returns (uint256) {
        return withdrawQueue.length;
    }

    function marketParams(Id id) external view returns (MarketParams memory) {
        return _params[id];
    }

    /* ------------------------------------------------------------------ */
    /*                               REALLOCATE                           */
    /* ------------------------------------------------------------------ */

    /// @notice Move liquidity between enabled markets (and the vault's idle balance).
    /// Withdrawals should be listed before supplies. Total supplied may not exceed
    /// total withdrawn plus idle balance (enforced by the token transfer itself).
    function reallocate(MarketAllocation[] calldata allocations) external onlyAllocatorRole {
        uint256 totalWithdrawn;
        uint256 totalSupplied;

        for (uint256 i; i < allocations.length; ++i) {
            MarketAllocation memory a = allocations[i];
            Id id = a.params.id();
            if (!config[id].enabled) revert UnauthorizedMarket(id);

            MERIDIAN.accrueInterest(a.params);
            uint256 supplied = MERIDIAN.expectedSupplyAssets(a.params, address(this));

            if (a.assets < supplied) {
                uint256 withdrawn;
                if (a.assets == 0) {
                    (uint256 shares,,) = MERIDIAN.position(id, address(this));
                    (withdrawn,) = MERIDIAN.withdraw(a.params, 0, shares, address(this), address(this));
                } else {
                    (withdrawn,) = MERIDIAN.withdraw(a.params, supplied - a.assets, 0, address(this), address(this));
                }
                totalWithdrawn += withdrawn;
                emit ReallocateWithdraw(msg.sender, id, withdrawn);
            } else if (a.assets > supplied) {
                uint256 toSupply = a.assets == type(uint256).max
                    ? _zeroFloorSub(totalWithdrawn, totalSupplied)
                    : a.assets - supplied;
                if (toSupply == 0) continue;
                if (supplied + toSupply > config[id].cap) revert SupplyCapExceeded(id);
                MERIDIAN.supply(a.params, toSupply, 0, address(this), "");
                totalSupplied += toSupply;
                emit ReallocateSupply(msg.sender, id, toSupply);
            }
        }
    }

    /* ------------------------------------------------------------------ */
    /*                         ERC-4626 ACCOUNTING                        */
    /* ------------------------------------------------------------------ */

    /// @notice Idle balance + supply in every enabled market, including interest
    /// accrued since each market's last update.
    function totalAssets() public view override returns (uint256 assets) {
        assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i; i < withdrawQueue.length; ++i) {
            assets += MERIDIAN.expectedSupplyAssets(_params[withdrawQueue[i]], address(this));
        }
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _accrueFee();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _accrueFee();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override returns (uint256) {
        _accrueFee();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override returns (uint256) {
        _accrueFee();
        return super.redeem(shares, receiver, owner_);
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner_), _availableLiquidity());
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        uint256 liquidShares = _convertToShares(_availableLiquidity(), Math.Rounding.Floor);
        return Math.min(super.maxRedeem(owner_), liquidShares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        _supplyMeridian(assets);
        _updateLastTotalAssets(lastTotalAssets + assets);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _withdrawMeridian(assets);
        _updateLastTotalAssets(_zeroFloorSub(lastTotalAssets, assets));
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Fill markets in supply-queue order up to each cap; remainder stays idle.
    function _supplyMeridian(uint256 assets) internal {
        for (uint256 i; i < supplyQueue.length && assets > 0; ++i) {
            Id id = supplyQueue[i];
            MarketParams memory p = _params[id];
            uint256 cap = config[id].cap;
            if (cap == 0) continue;

            MERIDIAN.accrueInterest(p);
            uint256 supplied = MERIDIAN.expectedSupplyAssets(p, address(this));
            uint256 room = _zeroFloorSub(cap, supplied);
            uint256 toSupply = Math.min(room, assets);
            if (toSupply > 0) {
                MERIDIAN.supply(p, toSupply, 0, address(this), "");
                assets -= toSupply;
            }
        }
    }

    /// @dev Use idle first, then pull from markets in withdraw-queue order,
    /// limited by each market's free liquidity.
    function _withdrawMeridian(uint256 assets) internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle >= assets) return;
        assets -= idle;

        for (uint256 i; i < withdrawQueue.length && assets > 0; ++i) {
            Id id = withdrawQueue[i];
            MarketParams memory p = _params[id];
            MERIDIAN.accrueInterest(p);

            uint256 supplied = MERIDIAN.expectedSupplyAssets(p, address(this));
            (uint256 tsa,, uint256 tba,) = MERIDIAN.expectedMarketBalances(p);
            uint256 liquidity = tsa - tba;
            uint256 toWithdraw = Math.min(Math.min(supplied, liquidity), assets);
            if (toWithdraw == 0) continue;

            if (toWithdraw == supplied) {
                (uint256 shares,,) = MERIDIAN.position(id, address(this));
                (toWithdraw,) = MERIDIAN.withdraw(p, 0, shares, address(this), address(this));
            } else {
                MERIDIAN.withdraw(p, toWithdraw, 0, address(this), address(this));
            }
            assets = _zeroFloorSub(assets, toWithdraw);
        }
        if (assets != 0) revert NotEnoughLiquidity();
    }

    function _availableLiquidity() internal view returns (uint256 liquidity) {
        liquidity = IERC20(asset()).balanceOf(address(this));
        for (uint256 i; i < withdrawQueue.length; ++i) {
            MarketParams memory p = _params[withdrawQueue[i]];
            uint256 supplied = MERIDIAN.expectedSupplyAssets(p, address(this));
            (uint256 tsa,, uint256 tba,) = MERIDIAN.expectedMarketBalances(p);
            liquidity += Math.min(supplied, tsa - tba);
        }
    }

    /* ------------------------------------------------------------------ */
    /*                                  FEES                              */
    /* ------------------------------------------------------------------ */

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        return assets.mulDiv(totalSupply() + feeShares + 10 ** _decimalsOffset(), newTotalAssets + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        return shares.mulDiv(newTotalAssets + 1, totalSupply() + feeShares + 10 ** _decimalsOffset(), rounding);
    }

    function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalAssets) {
        newTotalAssets = totalAssets();
        uint256 interest = _zeroFloorSub(newTotalAssets, lastTotalAssets);
        if (interest != 0 && fee != 0) {
            uint256 feeAssets = interest.mulDiv(fee, WAD);
            feeShares = feeAssets.mulDiv(
                totalSupply() + 10 ** _decimalsOffset(), newTotalAssets - feeAssets + 1, Math.Rounding.Floor
            );
        }
    }

    function _accrueFee() internal {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();
        if (feeShares != 0) _mint(feeRecipient, feeShares);
        _updateLastTotalAssets(newTotalAssets);
        emit AccrueFee(newTotalAssets, feeShares);
    }

    function _zeroFloorSub(uint256 x, uint256 y) internal pure returns (uint256) {
        return x > y ? x - y : 0;
    }

    function _updateLastTotalAssets(uint256 v) internal {
        lastTotalAssets = v;
    }
}
