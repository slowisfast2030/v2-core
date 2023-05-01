pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

// factory contract主要目的是创建流动性池子，每个流动性池子都是一个pair合约
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

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
        // arranges the two input tokens in ascending order while assigning them to respective variables.
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // checks if there isn't already another UniswapV2 pair created with the same tokens.
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // defines a memory variable called bytecode as the compiled contract creation code for UniswapV2Pair.
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // the create2() EVM opcode is used to deploy a new instance of UniswapV2Pair. The new pair is stored in the pair variable.
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        // 每创建一个交易对，就会触发PairCreated事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
