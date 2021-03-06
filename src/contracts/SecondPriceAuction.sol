//! Modified second price auction.
//! Copyright Parity Technologies, 2017.
//! Released under the Apache Licence 2.

pragma solidity ^0.4.16;

/// Stripped down ERC20 standard token interface.
contract Token {
	function transfer(address _to, uint256 _value) returns (bool success);
}

/// Stripped Badge token interface.
contract Certifier {
	function certified(address _who) constant returns (bool);
}

/// Simple Dutch Auction contract. Price starts high and monotonically decreases
/// until all tokens are sold at the current price with currently received
/// funds.
contract SecondPriceAuction {
	// Events:

	/// Someone bought in at a particular max-price.
	event Buyin(address indexed who, uint accepted, uint refund, uint price, uint bonus);

	/// Admin injected a purchase.
	event Injected(address indexed who, uint accepted, uint bonus);

	/// Admin injected a purchase.
	event PrepayBuyin(address indexed who, uint accepted, uint price, uint bonus);

	/// At least 20 blocks have passed.
	event Ticked(uint era, uint received, uint accounted);

	/// The sale just ended with the current price.
	event Ended(uint price);

	/// Finalised the purchase for `who`, who has been given `tokens` tokens.
	event Finalised(address indexed who, uint tokens);

	/// Auction is over. All accounts finalised.
	event Retired();

	// Constructor:

	/// Simple constructor.
	/// Token cap should take be in whole tokens, not smallest divisible units.
	function SecondPriceAuction(address _tokenContract, address _treasury, address _admin, uint _beginTime, uint _tokenCap) {
		tokenContract = Token(_tokenContract);
		treasury = _treasury;
		admin = _admin;
		beginTime = _beginTime;
		tokenCap = _tokenCap;
		endTime = beginTime + 15 days;
	}

	// Public interaction:

	/// Buyin function. Throws if the sale is not active. May refund some of the
	/// funds if they would end the sale.
	function buyin(uint8 v, bytes32 r, bytes32 s)
		payable
		when_not_halted
		when_active
		avoid_dust
		only_signed(msg.sender, v, r, s)
		only_basic(msg.sender)
		only_certified(msg.sender)
	{
		flushEra();

		uint accepted;
		uint refund;
		uint price;
		uint bonus;
		(accepted, refund, price, bonus) = theDeal(msg.value);

		// record the acceptance.
		participants[msg.sender].value += uint128(accepted);
		participants[msg.sender].bonus += uint128(bonus);
		totalAccounted += accepted;
		totalReceived += accepted - bonus;
		endTime = calculateEndTime();
		Buyin(msg.sender, accepted, refund, price, bonus);

		// send to treasury
		require (treasury.send(accepted - bonus));
		// issue refund
		require (msg.sender.send(refund));
	}

	/// Like buyin except no payment required.
	function prepayBuyin(uint8 v, bytes32 r, bytes32 s, address _who, uint128 _value)
	    when_not_halted
	    when_active
	    only_admin
	    only_signed(_who, v, r, s)
	    only_basic(_who)
	    only_certified(_who)
	{
		flushEra();

		uint accepted;
		uint refund;
		uint price;
		uint bonus;
		(accepted, refund, price, bonus) = theDeal(_value);

		/// No refunds allowed when pre-paid.
		require (refund == 0);

		participants[_who].value += uint128(accepted);
		participants[_who].bonus += uint128(bonus);
		totalAccounted += accepted;
		totalReceived += accepted - bonus;
		endTime = calculateEndTime();
		PrepayBuyin(_who, accepted, price, bonus);
	}

	/// Like buyin except no payment required and bonus automatically given.
	function inject(address _who, uint128 _spent)
	    only_admin
	    only_basic(_who)
	{
		uint128 bonus = _spent * uint128(BONUS_SIZE) / 100;
		uint128 value = _spent + bonus;

		participants[_who].value += value;
		participants[_who].bonus += bonus;
		totalAccounted += value;
		totalReceived += _spent;
		endTime = calculateEndTime();
		Injected(_who, value, bonus);
	}

	/// Mint tokens for a particular participant.
	function finalise(address _who)
		when_not_halted
		when_ended
		only_participants(_who)
	{
		// end the auction if we're the first one to finalise.
		if (endPrice == 0) {
			endPrice = totalAccounted / tokenCap;
			Ended(endPrice);
		}

		// enact the purchase.
		uint total = participants[_who].value;
		uint tokens = total / endPrice;
		totalFinalised += total;
		delete participants[_who];
		require (tokenContract.transfer(_who, tokens));

		Finalised(_who, tokens);

		if (totalFinalised == totalAccounted) {
			Retired();
		}
	}

	function flushEra() private {
		uint currentEra = (now - beginTime) / ERA_PERIOD;
		if (currentEra > eraIndex) {
			Ticked(eraIndex, totalReceived, totalAccounted);
		}
		eraIndex = currentEra;
	}

	// Admin interaction:

	/// Emergency function to pause buy-in and finalisation.
	function setHalted(bool _halted) only_admin { halted = _halted; }

	/// Emergency function to drain the contract of any funds.
	function drain() only_admin { require (treasury.send(this.balance)); }

	// Inspection:

	/// The current end time of the sale assuming that nobody else buys in.
	function calculateEndTime() constant returns (uint) {
		var factor = tokenCap / DIVISOR * USDWEI;
		return beginTime + 18432000 * factor / (totalAccounted + 5 * factor) - 5760;
	}

	/// The current price for a single indivisible part of a token. If a buyin happens now, this is
	/// the highest price per indivisible token part that the buyer will pay. This doesn't
	/// include the discount which may be available.
	function currentPrice() constant returns (uint weiPerIndivisibleTokenPart) {
		if (!isActive()) return 0;
		return (USDWEI * 18432000 / (now - beginTime + 5760) - USDWEI * 5) / DIVISOR;
	}

	/// Returns the total indivisible token parts available for purchase right now.
	function tokensAvailable() constant returns (uint tokens) {
		if (!isActive()) return 0;
		return tokenCap - totalAccounted / currentPrice();
	}

	/// The largest purchase than can be made at present, not including any
	/// discount.
	function maxPurchase() constant returns (uint spend) {
		if (!isActive()) return 0;
		return tokenCap * currentPrice() - totalAccounted;
	}

	/// Get the number of `tokens` that would be given if the sender were to
	/// spend `_value` now. Also tell you what `refund` would be given, if any.
	function theDeal(uint _value)
		constant
		returns (uint accepted, uint refund, uint price, uint bonus)
	{
		if (!isActive()) return;
		bonus = this.bonus(_value);
		price = currentPrice();
		accepted = _value + bonus;
		uint available = tokensAvailable();
		uint tokens = accepted / price;
		refund = 0;

		// if we've asked for too many, we should send back the extra.
		if (tokens > available) {
			// only accept enough of it to make sense.
			accepted = available * price;
			if (_value > accepted) {
				// bonus doesn't count in the refund.
				refund = _value - accepted;
			}
		}
	}

	/// Any applicable bonus to `_value` and returns it.
	function bonus(uint _value)
		constant
		returns (uint extra)
	{
		if (!isActive()) return 0;
		if (now < beginTime + BONUS_DURATION) {
			return _value * BONUS_SIZE / 100;
		}
		return 0;
	}

	/// True if the sale is ongoing.
	function isActive() constant returns (bool) { return now >= beginTime && now < endTime; }

	/// Returns true if the sender of this transaction is a basic account.
	function isBasicAccount(address _who) internal returns (bool) {
		uint senderCodeSize;
		assembly {
			senderCodeSize := extcodesize(_who)
		}
	    return senderCodeSize == 0;
	}

	// Modifiers:

	/// Ensure the sale is ongoing.
	modifier when_active { require (isActive()); _; }

	/// Ensure the sale is ended.
	modifier when_ended { require (now >= endTime); _; }

	/// Ensure we're not halted.
	modifier when_not_halted { require (!halted); _; }

	/// Ensure the sender sent a sensible amount of ether.
	modifier avoid_dust { require (msg.value >= DUST_LIMIT); _; }

	/// Ensure `_who` is a participant.
	modifier only_participants(address _who) { require (participants[_who].value != 0); _; }

	/// Ensure sender is admin.
	modifier only_admin { require (msg.sender == admin); _; }

	/// Ensure that the signature is valid.
	modifier only_signed(address who, uint8 v, bytes32 r, bytes32 s) { require (ecrecover(STATEMENT_HASH, v, r, s) == who); _; }

	/// Ensure sender is not a contract.
	modifier only_basic(address who) { require (isBasicAccount(who)); _; }

    /// Ensure sender has signed the contract.
	modifier only_certified(address who) {
		require (certifier.certified(who) && tx.gasprice <= 5000000000);
		_;
	}

	// State:

	struct Participant {
		uint128 value;
		uint128 bonus;
	}

	/// The auction participants.
	mapping (address => Participant) public participants;

	/// Total amount of ether received, excluding phantom "bonus" ether.
	uint public totalReceived = 0;

	/// Total amount of ether received, including phantom "bonus" ether.
	uint public totalAccounted = 0;

	/// Total amount of ether which has been finalised.
	uint public totalFinalised = 0;

	/// The current end time. Gets updated when new funds are received.
	uint public endTime;

	/// The price per token; only valid once the sale has ended and at least one
	/// participant has finalised.
	uint public endPrice;

	/// Must be false for any public function to be called.
	bool public halted;

	// Constants after constructor:

	/// The tokens contract.
	Token public tokenContract;

	/// The certifier.
	Certifier public certifier = Certifier(0xeAcDEd0D0D6a6145d03Cd96A19A165D56FA122DF);

	/// The treasury address; where all the Ether goes.
	address public treasury;

	/// The admin address; auction can be paused or halted at any time by this.
	address public admin;

	/// The time at which the sale begins.
	uint public beginTime;

	/// Maximum amount of tokens to mint. Once totalAccounted / currentPrice is
	/// greater than this, the sale ends.
	uint public tokenCap;

	// Era stuff (isolated)
	/// The era for which the current consolidated data represents.
	uint public eraIndex;

	/// The size of the era in seconds.
	uint constant public ERA_PERIOD = 5 minutes;

	// Static constants:

	/// Anything less than this is considered dust and cannot be used to buy in.
	uint constant public DUST_LIMIT = 5 finney;

	/// The hash of the statement which must be signed in order to buyin.
	bytes32 constant public STATEMENT_HASH = sha3(STATEMENT);

	/// The statement which should be signed.
	string constant public STATEMENT = "\x19Ethereum Signed Message:\n47Please take my Ether and try to build Polkadot.";

	//# Statement to actually sign.
	//# ```js
	//# statement = function() { this.STATEMENT().map(s => s.substr(28)) }
	//# ```

	/// Percentage of the purchase that is free during bonus period.
	uint constant public BONUS_SIZE = 15;

	/// Duration after sale begins that bonus is active.
	uint constant public BONUS_DURATION = 1 hours;

	/// Number of Wei in one USD, constant.
	uint constant public USDWEI = 1 ether / 250;

	/// Divisor of the token.
	uint constant public DIVISOR = 1000;

	// No default function, entry-level users
	function() { assert(false); }
}
