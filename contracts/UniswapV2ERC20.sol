pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    uint8 public constant decimals = 18;
    uint  public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    // 用于不同Dapp之间区分相同结构和内容的签名消息，该值有助于用户辨识哪些为信任的dapp
    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // 用于记录合约中每个地址使用链下签名消息的交易数量，防止重放攻击
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    // abi.encodePacked 将输入的参数根据其所需最低空间编码，类似abi.encode，但是会把其中填充的很多0给省略。当我们想要省略空间，且不与合约进行交互，可以使用abi.encodePacked、。例如：算一些数据的hash可以使用。
    // keccak算法是在以太坊中计算公钥的256位哈希，再截取这256位哈希的后160位哈希作为地址值。是哈希函数其中一种。
    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    /**
    permit方法实现的就是白皮书2.5节中介绍的“Meta transactions for pool shares 元交易”功能。
    代码中的digest的格式定义是来自EIP_721中的离线签名规范。
    用户签名的内容是（owner）授权（approve）某个合约（spender）在截止时间（deadline）之前花掉一定数量（value）的代币（Pair流动性代币）。
    periphery合约拿着签名的原始信息和签名生成的v,r,s，可以调用permit方法获得授权，permit方法可以使用ecrecover方法还原出签名地址为代币所有人，验证通过则批准授权。
     */
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }

    /**
    为什么有permit函数？
    permit函数主要实现了用户验证与授权，Uniswap V2的core函数虽然功能完善，但是对于用户来说却极不友好，
    用户需要借助它的周边合约才能和核心合约进行交互，但是在设计到流动性供给是，比如减少用户流动性，
    此时用户需要将自己的流动性代币燃烧掉，而由于用户调用的是周边合约，所以在未经授权的情况下是无法进行燃烧操作的，
    此时如果安装常规操作，那么用户需要先调用交易对合约对周边合约进行授权，之后再调用周边合约进行燃烧操作，
    而这个过程形成了两个不同合约的两个交易(无法合并到一个交易中)。
    如果我们通过线下消息签名，则可以减少其中一个交易，将所有操作放在一个交易里执行，确保了交易的原子性，
    在周边合约里，减小流动性来提取资产时，周边合约在一个函数内先调用交易对的permit函数进行授权，
    接着再进行转移流动性代币到交易对合约，提取代币等操作，所有操作都在周边合约的同一个函数中进行，达成了交易的原子性和对用户的友好性。
     */
}
