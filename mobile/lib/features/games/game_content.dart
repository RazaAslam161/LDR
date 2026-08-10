import 'package:miles/core/ui/content_language.dart';
import 'package:miles/features/games/no_repeat_bag.dart';
import 'package:miles/features/games/truth_dare_deck.dart';

/// Content engine for the games. Each prompt is composed from an opener + a
/// core, which multiplies a few dozen hand-written cores into hundreds of
/// natural-sounding variations — then [NoRepeatBag] deals them without repeats.
/// Net effect: effectively unlimited daily play that doesn't repeat.
///
/// Every pool exists twice, in English and Roman Urdu, and the two are written
/// **index-aligned**: entry 7 of one list says the same thing as entry 7 of the
/// other. That is what lets the two phones stay on the same card while each
/// partner reads it in their own language — the card is synced by index, not by
/// text. `test/unit/game_content_test.dart` pins the alignment, because a
/// single added line on one side would silently desync every card after it.

// ─────────────────────────────── Truth or Dare ───────────────────────────────

const _truthOpenersUr = [
  'Sach sach batao',
  'Bina jhijhak batao',
  'Dil pe haath rakh kar batao',
  'Honestly bolo',
  'Bina sharmaaye batao',
];

const _truthOpenersEn = [
  'Tell me honestly',
  'No holding back',
  'Hand on your heart',
  'Straight answer',
  'Say it without blushing',
];

const _dareOpenersUr = [
  'Abhi',
  'Is waqt',
  'Chalo abhi',
  'Bina der kiye',
  'Himmat hai to abhi',
];

const _dareOpenersEn = [
  'Right now',
  'This second',
  'Go on, now',
  'No stalling',
  'If you dare, now',
];

const _truthCoresUr = <TDTier, List<String>>{
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
    'meri kaunsi dress dekh kar socha bas ab milna zaroori hai',
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

const _truthCoresEn = <TDTier, List<String>>{
  TDTier.cute: [
    'what went through your heart the first time you saw me',
    'what is the sweetest memory we have made so far',
    'which little habit of mine do you find the most adorable',
    'when did you realise you were falling in love with me',
    'how many times a day do you think of me',
    'which photo of me do you quietly look at again and again',
    'if we were together today, how would we spend the perfect day',
    'what is it about my voice that calms you down',
    'which moment with me would you live all over again',
    'the one thing about me you have never told anyone',
    'the one thing I do that makes your whole day',
    'what time of day do you miss me the most',
    'have you ever dreamt about me, and what happened',
    'which part of my day do you look forward to hearing about',
    'if you had one word to describe me, what would it be',
    'which moment from our first conversation still sits with you',
    'which of my smiles goes straight to your heart',
    'what new pet name do you want to start calling me',
    'what about us are you the most proud of',
    'if we went on a date today, where would you take me',
    'which photo of me is your favourite on your phone',
    'what little thing about me makes you smile for no reason',
  ],
  TDTier.flirty: [
    'what part of me does your attention keep drifting back to',
    'which picture of mine has unsettled you the most',
    'if I walked in right now, what would you do first',
    'which pet name makes you melt when I say it',
    'have you ever lost sleep over me, and what kept you up',
    'my smile, my eyes or my voice — which one really gets you',
    'what is your first thought when you see me on a video call',
    'which thing I do makes you ache to see me',
    'what about me makes you a little bit jealous',
    'which outfit of mine made you think we need to meet soon',
    'is the last thought before you sleep usually me',
    'if I whispered something wicked in your ear, how would you react',
    'how do I still manage to unsettle you from this far away',
    'when you think about touching me, where do you start',
    'which of my messages made you blush the hardest',
    'which of my little habits pulls you in the most',
    'if I rested my head in your lap, what would you do',
    'where would you take me to impress me',
    'which photo of mine did you linger on the longest',
    'have you ever replayed an old voice note because you missed me',
  ],
  TDTier.spicy: [
    'what fantasy about me comes back to you the most',
    'the place you want my touch first',
    'which moment from our most intimate night never left your head',
    'if we were together tonight, what would your whole plan be',
    'which thing I do lights a fire in you',
    'has missing me alone ever made you impatient',
    'the one desire you want from me but have never said out loud',
    'what about me makes your control disappear on sight',
    'if I were next to you right now, where would you kiss me first',
    'your boldest desire, the one meant only for me',
    'how do you most love being touched by me',
    'the words that would undo you if I said them at night',
    'the very first thought that comes about our next time together',
    'the way of having me that drives you the most wild',
    'which picture of mine kept you awake all night',
    'how do you want to feel me close to you right now',
    'the one place on me your attention goes to first',
    'if nothing could stop you, what would you do with me right now',
    'which tone in my voice heats you up the most',
    'which fantasy of yours still lives only in your head',
  ],
};

const _dareCoresUr = <TDTier, List<String>>{
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

const _dareCoresEn = <TDTier, List<String>>{
  TDTier.cute: [
    'send a sweet voice note telling me why you like me',
    'send a selfie where you are smiling just for me',
    "write 'I love you' ten different ways and send it",
    'make my photo your wallpaper and send me the screenshot',
    'write me a short little poem with my name in it',
    'send the song that makes you think of me',
    'record twenty seconds of your voice complimenting me',
    'send a short video blowing me a kiss',
    'send a photo of the best thing about your day',
    'describe how you feel right now using only emojis',
    "write me a 'good night' note as if I were sitting right here",
    'close your eyes for thirty seconds in a memory of me, then tell me which one',
    'send me a photo of the smile you have on right now',
    'sing one line of the song that reminds me of you and send it',
  ],
  TDTier.flirty: [
    'send a selfie that will absolutely melt me',
    'say my name in your voice softly enough to make my heart race',
    'send a teasing voice note about what you will do when we meet',
    'send the photo with your most devastating look in it',
    'write a message that will have me blushing the moment I read it',
    "send a thirty-second video saying 'I miss you' your own way",
    'send a mischievous photo with a finger on your lips',
    'record yourself looking at me and naming the most attractive thing about me',
    "take and send a 'come here to me' photo",
    'show me on video the one move that will unsettle me',
    "say one line exactly like you mean 'you are mine'",
    'send a video giving me a wicked look with just your eyes',
  ],
  TDTier.spicy: [
    'send one photo in the mood (only as far as you are comfortable), just for me',
    'record yourself telling me softly what you wanted to do with me tonight',
    'show me or describe the place you want my kiss first',
    'send a voice note that lives out one fantasy entirely in words',
    'turn the lights low and send a photo in the mood (only as far as you want)',
    'write a message that is your full plan for tonight',
    "whisper 'good night' as if I were right beside you, and record it",
    'send a photo in the look that drives me wild (only as far as you are comfortable)',
    'write out one bold desire in full detail, meant only for me',
    'put your hand where you love being touched, imagine it is me, then tell me how it felt',
    'send a voice clip that will leave me restless',
    'imagine me in front of you and record something romantic in a low voice',
  ],
};

Map<TDTier, List<String>> _truthCores(ContentLanguage lang) =>
    lang == ContentLanguage.english ? _truthCoresEn : _truthCoresUr;

Map<TDTier, List<String>> _dareCores(ContentLanguage lang) =>
    lang == ContentLanguage.english ? _dareCoresEn : _dareCoresUr;

List<String> _truthOpeners(ContentLanguage lang) =>
    lang == ContentLanguage.english ? _truthOpenersEn : _truthOpenersUr;

List<String> _dareOpeners(ContentLanguage lang) =>
    lang == ContentLanguage.english ? _dareOpenersEn : _dareOpenersUr;

/// Every truth prompt for one tier, in one language, in a stable order.
///
/// The order is what the two phones agree on, so it is built the same way from
/// the same loop on both sides — index n is the same question everywhere.
List<String> truthPool(ContentLanguage lang, TDTier tier) => [
      for (final o in _truthOpeners(lang))
        for (final c in _truthCores(lang)[tier]!) '$o — $c?',
    ];

List<String> darePool(ContentLanguage lang, TDTier tier) => [
      for (final o in _dareOpeners(lang))
        for (final c in _dareCores(lang)[tier]!) '$o $c.',
    ];

/// Draw the next Truth/Dare card (no repeats until the pool is exhausted).
///
/// Returns the index too, so the drawing phone can tell the other *which* card
/// came up rather than what it said — the partner then renders it from their
/// own pool and reads it in their own language.
Future<TDCard> drawTD(ContentLanguage lang, TDType type, TDTier tier) async {
  final pool = _poolFor(lang, type, tier);
  final text = await NoRepeatBag.draw(_tdKey(type, tier, lang), pool);
  return TDCard(type, tier, text, pool.indexOf(text));
}

/// The card at [index], in *this* phone's language — or null when we cannot
/// place it.
///
/// Null rather than a fallback so the caller has to decide what to do about it.
/// The two decisions differ: what to SHOW falls back to the partner's words
/// (their sentence beats a blank card), but what to mark seen must not, or a
/// foreign-language string permanently occupies a slot in a bag it can never be
/// dealt from.
TDCard? localiseTD(ContentLanguage lang, TDType type, TDTier tier, int index) {
  final pool = _poolFor(lang, type, tier);
  if (index < 0 || index >= pool.length) return null;
  return TDCard(type, tier, pool[index], index);
}

List<String> _poolFor(ContentLanguage lang, TDType type, TDTier tier) =>
    type == TDType.truth ? truthPool(lang, tier) : darePool(lang, tier);

/// Mark a card seen (called when the partner draws it) so it won't repeat here.
///
/// Only for the language it was drawn in — the other pool holds different
/// strings, and burning a card there would retire a question nobody has read.
void markTDSeen(ContentLanguage lang, TDCard card) {
  NoRepeatBag.markSeen(_tdKey(card.type, card.tier, lang), card.text);
}

String _tdKey(TDType type, TDTier tier, ContentLanguage lang) =>
    'td_${type.name}_${tier.name}_${lang.name}';

// ─────────────────────────── Would You Rather ────────────────────────────────

const _wyrOpenersUr = [
  'Batao,',
  'Choose karo —',
  'Bolo,',
  'Dil se —',
  'Imagine karo,',
];

const _wyrOpenersEn = [
  'Tell me,',
  'Pick one —',
  'Go on,',
  'From the heart —',
  'Imagine this,',
];

const _wyrCoresUr = [
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

const _wyrCoresEn = [
  'one week asleep in my arms or a whole month of nightly video calls',
  'a kiss every morning when you wake or every night before you sleep',
  'hearing only my voice for life or only ever seeing my photos',
  'our next meeting long but far away or short but right now',
  'you surprise me with a visit or I surprise you',
  'one whole night just talking or one whole night just cuddling',
  'a long drive hand in hand or getting soaked in the rain together',
  'keeping a recording of my voice forever or a letter in my handwriting',
  'being held all day or teasing each other all day',
  'a slow dance by candlelight or a midnight walk under the moon',
  'five minutes looking into each other eyes or five minutes talking non-stop',
  'falling asleep in my lap or holding me while I fall asleep in yours',
  'telling me every one of your secrets or learning every one of mine',
  'a honeymoon in the mountains or by the sea',
  'a new pet name every day or a new compliment every day',
  'singing a song for each other or dancing together',
  'making up after every quarrel or telling me every joy first',
  'talking all night or feeling each other in the quiet',
  'me moving to your city or you moving to mine',
  'giving me your jacket in the cold or just pulling me into your arms',
  "letting me say 'I love you' first or saying it yourself",
  'a month of only texts or a single day together for real',
];

List<String> wyrPool(ContentLanguage lang) {
  final openers =
      lang == ContentLanguage.english ? _wyrOpenersEn : _wyrOpenersUr;
  final cores = lang == ContentLanguage.english ? _wyrCoresEn : _wyrCoresUr;
  return [
    for (final o in openers)
      for (final c in cores) '$o $c?',
  ];
}

// ─────────────────────────── Never Have I Ever ───────────────────────────────

const _nhiePrefixesUr = [
  'Maine kabhi',
  'Sach mein maine kabhi',
  'Kasam se maine kabhi',
  'Aaj tak maine kabhi',
];

const _nhiePrefixesEn = [
  'I have never',
  'I honestly have never',
  'I swear I have never',
  'To this day I have never',
];

const _nhieCoresUr = [
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

const _nhieCoresEn = [
  'scrolled up to reread our old chats',
  'screenshotted a photo of you while smiling at it',
  'lost time in the middle of work thinking about you',
  'pretended to fall asleep on purpose while talking to you',
  'felt a small sting of jealousy at you laughing with someone else',
  "kept talking for hours after saying 'good night'",
  'changed my profile picture over and over to impress you',
  'replayed a voice note just to hear your voice',
  'imagined the house we will live in one day',
  'waited for your message even while I was upset with you',
  "looked at you and thought 'I wish you were here right now'",
  'wanted to keep something of yours with me',
  "told you 'I am fine' when I was not",
  'stayed awake all night over one thing you said',
  'played out proposing to you in my head',
  'played one song on repeat because it reminded me of you',
  'proudly told a friend about you',
  'gone through your old photos because I missed you',
  'thought that you are the best decision of my life',
  'quietly put a heart emoji next to your name',
  'missed the way something of yours smells',
  'checked the mirror again and again before seeing you',
];

List<String> nhiePool(ContentLanguage lang) {
  final prefixes =
      lang == ContentLanguage.english ? _nhiePrefixesEn : _nhiePrefixesUr;
  final cores = lang == ContentLanguage.english ? _nhieCoresEn : _nhieCoresUr;
  return [
    for (final p in prefixes)
      for (final c in cores) '$p $c.',
  ];
}
