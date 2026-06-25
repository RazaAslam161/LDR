import 'package:miles/features/games/no_repeat_bag.dart';
import 'package:miles/features/games/truth_dare_deck.dart';

/// Content engine for the games. Each prompt is composed from an opener + a
/// core, which multiplies a few dozen hand-written cores into hundreds of
/// natural-sounding variations — then [NoRepeatBag] deals them without repeats.
/// Net effect: effectively unlimited daily play that doesn't repeat.

// ─────────────────────────────── Truth or Dare ───────────────────────────────

const _truthOpeners = [
  'Sach sach batao',
  'Bina jhijhak batao',
  'Dil pe haath rakh kar batao',
  'Honestly bolo',
  'Bina sharmaaye batao',
];

const _dareOpeners = [
  'Abhi',
  'Is waqt',
  'Chalo abhi',
  'Bina der kiye',
  'Himmat hai to abhi',
];

const _truthCores = <TDTier, List<String>>{
  TDTier.cute: [
    'mujhe pehli baar dekh kar tumhare dil mein kya aaya tha',
    'hamari ab tak ki sabse pyari yaad kaunsi hai',
    'meri kaunsi choti aadat tumhe sabse zyada cute lagti hai',
    'tumhe kab ehsaas hua ke tum mujhse mohabbat karne lage ho',
    'din mein kitni dafa meri yaad aati hai',
    'meri kaunsi tasveer tum chupke chupke baar baar dekhte ho',
    'agar hum aaj saath hote to perfect din kaise guzaarte',
    'meri awaaz mein aisa kya hai jo tumhe sukoon deta hai',
    'mere saath ka kaunsa lamha tum dobara jeena chahoge',
    'mere baare mein woh ek baat jo tum kisi ko nahi batate',
    'woh ek cheez jo main karoon to tumhara pura din ban jaata hai',
    'sabse zyada mujhe kis waqt miss karte ho',
    'kabhi mere baare mein koi sapna aaya hai, kya tha',
    'meri kaunsi baat ka tumhe har din intezaar rehta hai',
    'agar ek lafz mein meri tareef karni ho to kya kahoge',
    'hamari pehli baat ka koi lamha jo aaj bhi dil mein hai',
    'meri kaunsi smile tumhare dil ko choo jaati hai',
    'tum mujhe kis naye pyaar bhare naam se bulana chahte ho',
    'hamare rishte ki kaunsi baat par tumhe sabse zyada fakhr hai',
    'agar aaj date par jaate to kahaan le jaate mujhe',
    'meri kaunsi photo tumhare phone mein favourite hai',
    'mujhse judi kaunsi cheez tumhe bina wajah muskura deti hai',
  ],
  TDTier.flirty: [
    'meri kaunsi cheez par tumhara dhyan baar baar chala jaata hai',
    'meri kaunsi tasveer ne tumhe sabse zyada bechain kiya',
    'agar main abhi saamne hoti to pehla kaam kya karte',
    'kaunsa pyaar bhara naam loon to tum pighal jaate ho',
    'kabhi meri yaad mein neend udi hai, kis soch ne jagaaye rakha',
    'meri smile, aankhein ya awaaz — sabse zyada kya pasand hai',
    'video call par mujhe dekh kar pehla khayal kya aata hai',
    'meri kaunsi harkat tumhe milne ke liye taras dila deti hai',
    'meri kis baat par tumhe halki si jealousy hoti hai',
    "meri kaunsi dress dekh kar socha bas ab milna zaroori hai",
    'sone se pehle aakhri khayal aksar mera hota hai kya',
    'main tumhare kaan mein kuch shararati kahoon to reaction kya hoga',
    'door reh kar bhi main tumhe kaise pareshaan kar deti hoon',
    'mujhe chhoone ka khayal aaye to kahaan se shuru karoge',
    'mere kis message ne tumhara chehra sabse zyada laal kiya',
    'meri kaunsi adaa tumhe sabse zyada attract karti hai',
    'agar main tumhari godi mein sar rakhoon to kya karoge',
    'tum mujhe kis jagah le ja kar impress karna chahte ho',
    'meri kaunsi photo par tum sabse der tak ruke the',
    'kabhi mujhe miss karke meri purani voice note suni hai',
  ],
  TDTier.spicy: [
    'mujhe le kar tumhari sabse zyada aane wali fantasy kya hai',
    'woh jagah jahaan tum sabse pehle mera touch chahte ho',
    'hamari sabse intimate raat ka kaunsa lamha zehan se nahi gaya',
    'agar aaj raat hum saath hote to tumhara pura plan kya hota',
    'meri kaunsi adaa tumhare andar aag laga deti hai',
    'akele mein meri yaad ne kabhi tumhe besabra kiya hai',
    'woh ek khwahish jo tum mujhse karna chahte ho par kaha nahi',
    'mujhpe woh kya hai jise dekhte hi tumhara control khatam ho jaata hai',
    'agar main abhi tumhare paas hoti to pehla kiss kahaan karte',
    'apni sabse bold khwahish jo sirf mere saath poori karni hai',
    'mujhe kis tarah chhoona tumhe sabse zyada pasand hai',
    'woh lafz jo main raat ko kahoon to tum bekaaboo ho jaao',
    'hamari agli mulaqat par sabse pehla khayal jo aata hai',
    'mujhe kis andaaz mein paana tumhe sabse zyada pagal karta hai',
    'meri kaunsi tasveer ne tumhari raat jagaaye rakhi',
    'tum mujhe abhi kis tarah apne kareeb mehsoos karna chahte ho',
    'woh ek jagah meri jahaan tumhara dhyan sabse pehle jaata hai',
    'agar koi rok-tok na ho to abhi mere saath kya karte',
    'meri awaaz ka kaunsa andaaz tumhe sabse zyada garam karta hai',
    'tumhari kaunsi fantasy hai jo abhi tak sirf soch mein hai',
  ],
};

const _dareCores = <TDTier, List<String>>{
  TDTier.cute: [
    'ek pyari voice note bhejo jisme batao main kyun pasand hoon',
    'ek selfie bhejo jisme sirf mere liye muskura rahe ho',
    "'I love you' das alag andaaz mein likh kar bhejo",
    'apne phone ka wallpaper meri tasveer laga kar screenshot bhejo',
    'mere naam ki ek choti shayari likh kar bhejo',
    'woh gaana bhejo jo sun kar tum meri yaad karte ho',
    '20 second apni awaaz mein meri tareef karke bhejo',
    'ek flying kiss wali choti video bhejo',
    'apni aaj ki sabse achi cheez ki photo bhejo',
    'apni abhi wali feeling sirf emojis mein bayaan karo',
    "ek 'good night' note likho jaise main saamne baitha hoon",
    'aankhein band karke 30 second meri pyari yaad mein kho jao, phir batao',
    'mujhe apni abhi wali muskaan ki photo bhejo',
    'ek line gaa kar voice note bhejo jo mujhe yaad dilati hai',
  ],
  TDTier.flirty: [
    'ek aisi selfie bhejo jo dekh kar main pighal jaun',
    'apni awaaz mein mera naam itne pyaar se lo ke dhadkan tez ho jaaye',
    'ek teasing voice note bhejo ke milne par kya karoge',
    'apni sabse killer nazar wali photo bhejo',
    'ek aisa message likho jo padhte hi mera chehra laal ho jaaye',
    "30 second ki video bhejo jisme apne andaaz mein 'I miss you' kaho",
    'apne honth par ungli rakh kar ek shararati photo bhejo',
    'meri sabse attractive cheez bol kar, mujhe dekhte hue record karo',
    "ek 'aa jao mere paas' wali photo banao aur bhejo",
    'woh harkat video mein dikhao jo mujhe bechain kar degi',
    "ek line bolo bilkul 'tum mere ho' wale andaaz mein",
    'apni aankhon se ek shararati ishaara karke video bhejo',
  ],
  TDTier.spicy: [
    'ek mood wali photo bhejo (jitna comfortable ho) sirf mere liye',
    'halki awaaz mein woh batao jo aaj raat mere saath karna chahte the, record karo',
    'woh jagah dikhao ya describe karo jahaan sabse pehle mera kiss chahte ho',
    'ek voice note bhejo jisme apni ek fantasy sirf lafzon mein poori karo',
    'lights halki karke ek mood wali photo bhejo (jitna chaho)',
    'ek message likho jo bilkul tonight ke liye tumhara pura plan ho',
    "whisper wali awaaz mein 'good night' bolo jaise main paas hoon, record karo",
    'woh look jo mujhe pagal karta hai usme ek photo bhejo (jitna comfortable ho)',
    'apni ek bold khwahish poore detail mein likho jo sirf mere saath poori karni hai',
    'apne soft touch wali jagah par haath rakh kar socho main hoon, phir batao kaisa laga',
    'ek aisi awaaz wali clip bhejo jo mujhe bechain kar de',
    'mujhe saamne imagine karke ek romantic baat halki awaaz mein record karo',
  ],
};

final Map<TDTier, List<String>> _truthPools = {
  for (final t in TDTier.values)
    t: [
      for (final o in _truthOpeners)
        for (final c in _truthCores[t]!) '$o — $c?',
    ],
};

final Map<TDTier, List<String>> _darePools = {
  for (final t in TDTier.values)
    t: [
      for (final o in _dareOpeners)
        for (final c in _dareCores[t]!) '$o $c.',
    ],
};

/// Draw the next Truth/Dare card (no repeats until the pool is exhausted).
Future<TDCard> drawTD(TDType type, TDTier tier) async {
  final pool = type == TDType.truth ? _truthPools[tier]! : _darePools[tier]!;
  final text = await NoRepeatBag.draw(_tdKey(type, tier), pool);
  return TDCard(type, tier, text);
}

/// Mark a card seen (called when the partner draws it) so it won't repeat here.
void markTDSeen(TDCard card) {
  NoRepeatBag.markSeen(_tdKey(card.type, card.tier), card.text);
}

String _tdKey(TDType type, TDTier tier) => 'td_${type.name}_${tier.name}';

// ─────────────────────────── Would You Rather ────────────────────────────────

const _wyrOpeners = [
  'Batao,',
  'Choose karo —',
  'Bolo,',
  'Dil se —',
  'Imagine karo,'
];

const _wyrCores = [
  "ek hafta meri baahon mein so'na ya mahina bhar roz video call",
  'roz subah uth kar kiss karna ya roz raat sone se pehle',
  "saari zindagi sirf meri awaaz sun'na ya sirf meri tasveerein dekhna",
  'agli mulaqat lambi par door ya choti par abhi',
  'tum mujhe surprise visit karo ya main tumhe',
  'ek raat sirf baatein ya ek raat sirf cuddle',
  'long drive haath mein haath ya barish mein bheegna saath',
  'meri awaaz wali recording rakhna hamesha ya mera handwritten letter',
  'saara din gale lage rehna ya saara din ek dusre ko tease karna',
  'slow dance candle light mein ya midnight walk chand ke neeche',
  'ek dusre ki aankhon mein 5 minute dekhna ya 5 minute non-stop baatein',
  "meri god mein so'na ya apni god mein mujhe sulaana",
  'apni har secret bata dena ya meri har secret jaan lena',
  'honeymoon pahaadon par ya samandar kinare',
  'roz ek naya pyaar bhara naam ya roz ek nayi tareef',
  'ek dusre ke liye gaana gaana ya saath dance karna',
  'har naraazgi par manana ya har khushi sabse pehle batana',
  'saari raat jaag kar baatein ya khamoshi mein ek dusre ko mehsoos karna',
  'mere shehar shift hona ya main tumhare',
  'thand mein apni jacket dena ya baahon mein chhupa lena',
  "mujhe pehle 'I love you' bolne dena ya khud bolna",
  'ek mahina sirf texts ya ek din asli mulaqat',
];

final List<String> wyrPool = [
  for (final o in _wyrOpeners)
    for (final c in _wyrCores) '$o $c?',
];

// ─────────────────────────── Never Have I Ever ───────────────────────────────

const _nhiePrefixes = [
  'Maine kabhi',
  'Sach mein maine kabhi',
  'Kasam se maine kabhi',
  'Aaj tak maine kabhi',
];

const _nhieCores = [
  'tumhari purani chat upar scroll karke dobara nahi padhi',
  'tumhari photo dekh kar muskuraate hue screenshot nahi liya',
  'kaam ke beech tumhari yaad mein waqt nahi guzaara',
  'tumse baat karte hue jaan-boojh kar so jaane ka natak nahi kiya',
  'tumhari kisi aur se hansi par halki jealousy feel nahi ki',
  "'good night' ke baad bhi ghanton baat nahi ki",
  'tumhe impress karne ke liye apni DP baar baar nahi badli',
  'tumhari awaaz sunne ke liye voice note replay nahi kiya',
  'tumhare saath future ke ghar ka sapna nahi dekha',
  'naraz hote hue bhi tumhare message ka intezaar nahi kiya',
  "tumhe dekh kar 'kaash abhi paas hote' nahi socha",
  'tumhari koi cheez apne paas rakhne ka mann nahi kiya',
  "tumse 'main theek hoon' ka jhoot nahi bola jab theek nahi tha",
  'tumhari ek baat par poori raat soch kar nahi guzaari',
  'tumhe propose karne ka scene dimaag mein nahi banaya',
  'tumhari yaad mein koi gaana baar baar nahi sunaa',
  'tumhare saath ki baat kisi dost ko fakhr se nahi batayi',
  'tumhe miss karte hue tumhari purani photos nahi dekhi',
  'socha nahi ke tum meri zindagi ka sabse acha faisla ho',
  'tumhare naam ke aage chupke se dil wala emoji nahi lagaya',
  'tumhari kisi cheez ki khushboo miss nahi ki',
  'tumse milne se pehle aaina baar baar nahi dekha',
];

final List<String> nhiePool = [
  for (final p in _nhiePrefixes)
    for (final c in _nhieCores) '$p $c.',
];
