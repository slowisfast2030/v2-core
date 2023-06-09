pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

//Pair合约主要实现了三个方法：mint（添加流动性）、burn（移除流动性）、swap（兑换）。

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    // 定义了最小流动性，在提供初始流动性时会被燃烧掉
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 用于计算ERC-20合约中转移资产的transfer对应的函数选择器
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 用于存储factory合约地址
    // 很好奇：这个factory是什么时候赋值的？？？
    address public factory;
    // 用于存储两个token的地址
    address public token0;
    address public token1;

    // 最新恒定乘积中两种代币的数量
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    // 记录交易时的区块创建时间
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    // 记录交易对中两种价格的累计值
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    // 某一时刻恒定乘积中的积的值，主要用于开发团队手续费的计算
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    
    // 表示未被锁上的状态，用于下面的修饰器
    uint private unlocked = 1;
    /**
    在调用该lock修饰器的函数首先检查unlocked 是否为1，如果不是则报错被锁上，如果是为1，则将unlocked赋值为0（锁上），
    之后执行被修饰的函数体，此时unlocked已成为0，之后等函数执行完之后再恢复unlocked为1。
     */
    /**
    这段代码是用来防止重入攻击的。当函数被外部调用时，unlocked设置为0，函数执行完后才会重新设置为1.
    在未执行完之前，如果有其他人调用该函数，这是unlocked已经为0，无法通过修饰器重的require检查。
    当然这里也可以不用0和1，用true和false也是可以的。
     */
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _; //表示被修饰的函数内容
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // 使用代币的call函数去调用代币合约transfer来发送代币，在这里会检查call调用是否成功以及返回值是否为true
    // 可以简单思考下，这里的to是什么地址？
    // token假设是DAI合约的地址
    // 那么to可能是当前合约的地址，也可能是外部用户的地址（提供流动性的用户）
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // 进行合约初始化。因为factory合约使用create2函数创建交易对合约，无法向构造函数传递参数，所以需要单独写一个初始化函数
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 验证 balance0 和 blanace1 是否 uint112 的上限
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 只取后32位
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 计算当前区块和上一个区块之间的时间差
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        /**
        时间差（两个区块的时间差，不是同一个区块）大于0并且两种资产的数量不为0，才可以进行价格累计计算，
        如果是同一个区块的第二笔交易及以后的交易，timeElapsed则为0，此时不会计算价格累计值。
         */
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新reserve0，reserve1，blockTimestampLast
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // _mintFee()用于在添加流动性和移除流动性时，计算开发团队手续费
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    
    // mint()用于用户提供流动性时(提供一定比例的两种ERC-20代币)增加流动性代币给流动性提供者    
    /**
    参数to（表示流动性代币将要转到哪个地址）
    从外部（external）可调用合约
    需要加锁（因为该函数可能会同时被多个用户调用），返回值为流动性代币数量。
     */

    // 这个函数挺奇怪的。既然是注入流动性，函数参数却没有amount0和amount1。这两个值是通过计算得到的。
    
    // this low-level function should be called from a contract which performs important safety checks
    // 这是一个低等级函数。核心合约对用户不友好，需要通过周边合约来简介交互
    
    /**
    Keegan小钢：
    既然这是一个添加流动性的底层函数，那参数里为什么没有两个代币投入的数量呢？
    这可能是大部分人会想到的第一个问题。其实，调用该函数之前，路由合约已经完成了将用户的代币数量划转到该配对合约的操作。
    因此，你看前五行代码，通过获取两个币的当前余额 balance0 和 balance1，
    再分别减去 _reserve0 和 _reserve1，即池子里两个代币原有的数量，
    就计算得出了两个代币的投入数量 amount0和 amount1。
    另外，还给该函数添加了 lock 的修饰器，这是一个防止重入的修饰器，
    保证了每次添加流动性时不会有多个用户同时往配对合约里转账，不然就没法计算用户的 amount0 和 amount1 了。
     */

    /**
    铸币流程发生在router合约向pair合约发送代币之后，因此此次的储备量和合约的token余额是不相等的，
    中间的差值就是需要铸币的token金额，即amount0和amount1。
     */
    // 这里的to就是流动性提供者的地址
    // 需要特别明确，这里有三个账本（合约）：token0代币账本、token1代币账本，当前合约
    // 当前合约有erc20合约的所有函数，当前合约有自己的代币，用来给流动性提供者发token
    function mint(address to) external lock returns (uint liquidity) {
        // 这里使用了一个小技巧来减少 gas 开销，使用了 uint112 类型来存储代币存储量，
        // 因为根据 Uniswap 规则，代币存储量最多为 2^112 ~ 5.2 × 10^33，可以使用 uint112 类型减少 gas 开销。
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings

        // balance0和balance1是流动性池中当前交易对的资产数量
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // amount0和amount1是计算用户新注入的两种ERC20代币的数量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        /**
        在if语句中，如果_totalSupply为0，则说明是初次提供流动性，会根据恒定乘积公式的平方根来计算，
        同时要减去已经燃烧掉的初始流动性值，具体为MINIMUM_LIQUIDITY；
        如果_totalSupply不为0，则会根据已有流动性按比例增发，
        由于注入了两种代币，所以会有两个计算公式，每种代币按注入比例计算流动性值，取两个中的最小值。
         */
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }

        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 思考下这里的_mint函数的意义？
        // 
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);

        // 如果分成开关打开，更新K值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        
        // Mint事件：msg.sender为流动性提供者，amount0和amount1为提供的两种资产数量
        emit Mint(msg.sender, amount0, amount1);
    }

    // burn()用于燃烧流动性代币来提取相应的两种资产，并减少交易对的流动性
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        
        // 移除流动性需要修改3个账本
        // 1.流动性代币账本：就是当前合约的balanceOf和totalSupply的操作
        // 2.两种资产账本：需要进行函数调用
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 传入的参数amount0Out，amount1Out,to以及data分别是要购买的token0的数量，token1的数量，接收者的地址，接收后执行回调传递数据。
    // 困惑的点：这里为何有两个amountOut？
    /**
    new bing:
    The swap function is the core function that enables flash swaps. 
    The swap function takes four parameters: amount0Out, amount1Out, to, and data.

    amount0Out and amount1Out are the desired amounts of token0 and token1 to receive from the swap. 
    One of them must be zero, and the other must be positive.

    to is the address that will receive the output tokens from the swap. 
    It can be any address, including another smart contract.

    data is an optional parameter that can contain arbitrary bytes. 
    It can be used to pass additional information or instructions to the recipient of the output tokens.
     */
    
    /**
    swap函数不能被用户直接调用的原因是它不使用标准的ERC-20 transferFrom函数来接收代币，而是检查pair合约的当前和存储的余额之间的差异。
    这意味着在调用swap函数之前，必须先将代币转移到pair合约，否则它会回滚。

    如果用户直接将代币转移到pair合约，然后再调用swap函数，这样做是不安全的，因为转移的代币可能会被套利者利用。
    因此，swap函数必须由另一个智能合约来调用，以保证原子性。

    为了方便用户进行交换，Uniswap v2提供了一个外围合约UniswapV2Router02.sol，它包含了各种交换代币的函数，有不同的选项。
    例如，有些函数允许用ETH交换ERC-20代币或反之，有些函数允许指定输入或输出代币的数量，有些函数允许设置截止时间或最小输出代币数量等。

    用户可以通过外围合约来间接地调用swap函数，实现他们想要的交易。
     */

    /**
    Keegan小钢:
    amount0Out 和 amount1Out 表示兑换结果要转出的 token0 和 token1 的数量，
    这两个值通常情况下是一个为0，一个不为0，但使用闪电交易时可能两个都不为0。
    to 参数则是接收者地址，最后的 data 参数是执行回调时的传递数据，通过路由合约兑换的话，该值为0。
     */ 
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // token0和token1哪一个是要购买的token？好问题！
        /**
        The function first checks whether the output amounts are greater than 0 and 
        whether there is enough liquidity in the pool to make the trade. If these conditions are not met, the function will revert.
         */
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;

        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');

        // 如果amount0Out大于0，说明要购买token0，则将token0转给 to
        // 如果amount1Out大于0，则说明要购买token1，则将token1转给to
        // 有没有可能同时购买两种代币呢？
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens

        // 闪电贷的回调函数
        // 普通交易调用的data为空，不会执行回调。闪电贷调用的data不为空，会执行回调。
        // uniswapV2Call函数是一个可选的回调函数，它允许接收者在接收代币后执行任意代码。
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

        // 获取最新的t0和t1余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }

        // amountIn = balance - (_reserve - amountOut)
        // 根据取出的储备量、原有储备量以及最新的余额，反推得到输入的数额
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        // 调整后的余额 = 最新余额 - 扣税金额 （相当于乘以997/1000）
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

        // 恒定乘积校验。新的值要大于等于旧的值
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        // Swap事件可以很清楚看到各个参数的含义
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
