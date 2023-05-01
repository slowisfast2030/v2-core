pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

// factory contract主要目的是创建流动性池子，每个流动性池子都是一个pair合约
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // 收税地址（0.005%的协议费用，到目前为止uniswap也没有设置）
    address public feeToSetter; // 收税权限地址

    // 前两个地址分别对应交易对中的两种代币地址，最后一个地址是交易对合约本身地址
    // 疑问：代币的地址是什么？
    mapping(address => mapping(address => address)) public getPair;
    // 用于存放所有交易对（代币对）合约地址信息
    address[] public allPairs;

    // PairCreated 事件在createPair方法中触发，保存交易对的信息（两种代币地址，交易对本身地址，创建交易对的数量）
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    // 返回到目前为止通过工厂创建的交易对的总数。潜台词：通过这个工厂方法，可以创建多个交易对
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // tA 和 tB 进行排序，确保tA小于tB。返回对应的t0和t1
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        // // 判断tA 地址不为0，继而判断出tB 地址也不为0
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        
        // 校验tA 和 tB 的地址不存在配对过
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        
        // 通过引入UniswapV2Pair合约，不使用继承的方式。
        // 使用type(合约名称).creationCode 方法获得该合约编译之后的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;

        // abi.encodePacked()     编码打包
        // keccak256              Solidity 内置加密Hash方法
        // keccak256(abi.encodePacked(a, b))是计算keccak256(a, b)更明确的方式
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        // 内联汇编
        // mload(bytecode)          返回长度
        // create2                  新的操作码 （opcode 操作码是程序的低级可读指令, 所有操作码都具有对应的十六进制值）
        assembly {                  // 使用汇编Opcode来操作EVM字节码，可以节省gas和做一些无法通过Solidity完成的事情
        //通过create2方法布署合约,并且加盐,返回地址到pair变量
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        // 调用pair合约的初始化方法，传入参数tA tB
        IUniswapV2Pair(pair).initialize(token0, token1);

        // pair是合约地址
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        // 每创建一个交易对，就会触发PairCreated事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 设置收税地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    // 设置收税权限
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
