import 'dart:math';

/// Truth or Dare content for couples, written in natural, human-sounding Roman
/// Urdu. Three heat levels so a couple can keep it sweet or turn it up:
///   • cute   – wholesome, romantic
///   • flirty – playful, teasing
///   • spicy  – intimate / adult, but tasteful (it prompts *them* to express
///              desire; the photo/voice dares always say "jitna comfortable ho"
///              so consent is baked into the game itself)
enum TDType { truth, dare }

enum TDTier { cute, flirty, spicy }

extension TDTierMeta on TDTier {
  String get label => switch (this) {
        TDTier.cute => 'Cute',
        TDTier.flirty => 'Flirty',
        TDTier.spicy => 'Spicy',
      };
  String get emoji => switch (this) {
        TDTier.cute => '🌸',
        TDTier.flirty => '😏',
        TDTier.spicy => '🔥',
      };
}

class TDCard {
  const TDCard(this.type, this.tier, this.text);
  final TDType type;
  final TDTier tier;
  final String text;

  Map<String, dynamic> toJson() =>
      {'type': type.name, 'tier': tier.name, 'text': text};

  static TDCard? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final type = TDType.values
        .where((t) => t.name == j['type'])
        .cast<TDType?>()
        .firstWhere((_) => true, orElse: () => null);
    final tier = TDTier.values
        .where((t) => t.name == j['tier'])
        .cast<TDTier?>()
        .firstWhere((_) => true, orElse: () => null);
    final text = j['text'] as String?;
    if (type == null || tier == null || text == null) return null;
    return TDCard(type, tier, text);
  }
}

final _rng = Random();

/// Draw a random card of the given type + tier.
TDCard drawCard(TDType type, TDTier tier) {
  final pool =
      truthDareDeck.where((c) => c.type == type && c.tier == tier).toList();
  if (pool.isEmpty) {
    return const TDCard(TDType.truth, TDTier.cute,
        'Apne partner ko abhi ek pyari si baat bolo. 💛');
  }
  return pool[_rng.nextInt(pool.length)];
}

const truthDareDeck = <TDCard>[
  // ─────────────────────────── TRUTHS · CUTE ───────────────────────────
  TDCard(TDType.truth, TDTier.cute,
      'Sach sach batao — mujhe pehli baar dekh kar tumhare dil mein kya aaya tha?'),
  TDCard(TDType.truth, TDTier.cute,
      'Hamari ab tak ki sabse pyari yaad kaunsi hai jo har baar tumhe muskura deti hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Meri kaunsi choti si aadat hai jo tumhe sabse zyada cute lagti hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Tumhe theek se kab ehsaas hua ke tum mujhse mohabbat karne lage ho?'),
  TDCard(TDType.truth, TDTier.cute,
      'Sach batao, poore din mein kitni dafa meri yaad aati hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Meri kaunsi tasveer hai jo tum chupke chupke baar baar dekhte ho?'),
  TDCard(TDType.truth, TDTier.cute,
      'Agar hum aaj saath hote to apna perfect din kaise guzaarte?'),
  TDCard(TDType.truth, TDTier.cute,
      'Meri awaaz mein aisa kya hai jo tumhe sukoon de deta hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Mere saath ka woh kaunsa lamha hai jise tum dobara jeena chahoge?'),
  TDCard(TDType.truth, TDTier.cute,
      'Mere baare mein woh ek baat jo tum aaj tak kisi ko nahi batate?'),
  TDCard(TDType.truth, TDTier.cute,
      'Woh ek cheez jo main karoon to tumhara pura din ban jaata hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Hamari pehli baat-cheet ka koi lafz aaj bhi dil mein basa hai?'),
  TDCard(TDType.truth, TDTier.cute,
      'Sabse zyada miss kab karte ho mujhe — subah, raat, ya kis waqt?'),
  TDCard(TDType.truth, TDTier.cute,
      'Kabhi mere baare mein koi sapna aaya hai? Sach batao kya tha.'),
  TDCard(TDType.truth, TDTier.cute,
      'Meri kaunsi baat hai jiska tumhe sabse zyada intezaar rehta hai har din?'),
  TDCard(TDType.truth, TDTier.cute,
      'Agar tumhe ek lafz mein meri tareef karni ho to kya kahoge?'),

  // ─────────────────────────── TRUTHS · FLIRTY ──────────────────────────
  TDCard(TDType.truth, TDTier.flirty,
      'Sach batao — meri kaunsi cheez par tumhara dhyan baar baar chala jaata hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Meri kaunsi tasveer ne tumhe sabse zyada bechain kiya hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Agar main abhi saamne hoti/hota, to pehla kaam kya karte — bina sharmaaye batao.'),
  TDCard(TDType.truth, TDTier.flirty,
      'Woh kaunsa pyaar bhara naam hai jo main loon to tum bilkul pighal jaate ho?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Kabhi meri yaad mein neend udi hai? Kis soch ne jagaaye rakha?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Meri smile, aankhein, ya awaaz — sach mein sabse zyada kya pasand hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Video call pe mujhe dekh kar dimaag mein sabse pehle kya khayal aata hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Meri kaunsi harkat tumhe milne ke liye taras dila deti hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Sach bolo — meri kis baat par tumhe halki si jealousy hoti hai?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Meri kaunsi dress ya look dekh kar tumne socha "bas ab milna zaroori hai"?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Sone se pehle aakhri khayal aksar mera hota hai? Sach bol do.'),
  TDCard(TDType.truth, TDTier.flirty,
      'Agar main tumhare kaan mein kuch shararati kahoon to tumhara reaction kya hoga?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Woh ek tareeqa jisse main door reh kar bhi tumhe pareshaan kar deti/deta hoon?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Mujhe chhoone ka khayal aaye to sabse pehle kahaan se shuru karte?'),
  TDCard(TDType.truth, TDTier.flirty,
      'Mere kis message ne tumhara chehra sabse zyada laal kiya hai?'),

  // ─────────────────────────── TRUTHS · SPICY ───────────────────────────
  TDCard(TDType.truth, TDTier.spicy,
      'Sach batao — mujhe le kar tumhari sabse zyada aane wali fantasy kya hai?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Woh jagah jahaan tum sabse pehle mera touch mehsoos karna chahte ho?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Hamari sabse intimate raat ka kaunsa lamha aaj tak zehan se nahi gaya?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Agar aaj raat hum saath hote, to tumhara pura plan kya hota — detail mein.'),
  TDCard(TDType.truth, TDTier.spicy,
      'Meri kaunsi adaa hai jo tumhare andar aag laga deti hai?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Sach bolo, akele mein meri yaad ne kabhi tumhe besabra kiya hai?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Woh ek khwahish jo tum mujhse karna chahte ho par ab tak kaha nahi?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Mujhpe woh kaunsi cheez hai jise dekhte hi tumhara saara control khatam ho jaata hai?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Agar main abhi tumhare paas hoti/hota, sabse pehla kiss kahaan karte?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Apni sabse bold khwahish batao jo sirf mere saath poori karni hai.'),
  TDCard(TDType.truth, TDTier.spicy,
      'Mujhe kis tarah chhoona tumhe sabse zyada pasand hai — halka halka ya...?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Woh awaaz ya lafz jo main raat ko kahoon to tum bekaaboo ho jaao?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Sach batao — meri kis tasveer par tumne sabse der tak nazar tikaayi?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Hamari agli mulaqat par sabse pehla khayal jo tumhare dimaag mein aata hai?'),
  TDCard(TDType.truth, TDTier.spicy,
      'Mujhe kis andaaz mein dekhna ya paana tumhe sabse zyada pagal karta hai?'),

  // ─────────────────────────── DARES · CUTE ─────────────────────────────
  TDCard(TDType.dare, TDTier.cute,
      'Abhi ek pyari si voice note bhejo jisme tum bata rahe ho ke main tumhe kyun pasand hoon.'),
  TDCard(TDType.dare, TDTier.cute,
      'Ek selfie bhejo jisme tum sirf mere liye muskura rahe ho.'),
  TDCard(TDType.dare, TDTier.cute,
      'Mujhe "I love you" das alag andaaz mein likh kar bhejo — har baar naya style.'),
  TDCard(TDType.dare, TDTier.cute,
      'Abhi apne phone ka wallpaper meri tasveer laga kar screenshot bhejo.'),
  TDCard(TDType.dare, TDTier.cute,
      'Mere naam ki ek choti si shayari ya poem likho aur abhi bhejo.'),
  TDCard(TDType.dare, TDTier.cute,
      'Mujhe woh gaana bhejo jo sun kar tum meri yaad karte ho — aur batao kyun.'),
  TDCard(TDType.dare, TDTier.cute,
      'Apni awaaz mein 20 second meri tareef karte hue ek clip bhejo.'),
  TDCard(TDType.dare, TDTier.cute,
      'Mujhe ek flying kiss wali choti video bhejo — sharmaana bilkul mana hai.'),
  TDCard(TDType.dare, TDTier.cute,
      'Apni aaj ki sabse achi cheez dikhane ke liye ek photo bhejo.'),
  TDCard(TDType.dare, TDTier.cute,
      'Abhi apni feeling sirf emojis mein bayaan karo — bina lafzon ke.'),
  TDCard(TDType.dare, TDTier.cute,
      'Mere liye ek "good night" note likho jaise main bilkul saamne baitha/baithi hoon.'),
  TDCard(TDType.dare, TDTier.cute,
      'Aankhein band karke 30 second meri ek pyari yaad mein kho jao, phir batao kya yaad aaya.'),

  // ─────────────────────────── DARES · FLIRTY ───────────────────────────
  TDCard(TDType.dare, TDTier.flirty,
      'Ek aisi selfie bhejo jisme tum jaante ho ke main dekh kar pighal jaunga/jaungi.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Apni awaaz mein mera naam itne pyaar se lo aur record karke bhejo ke dhadkan tez ho jaaye.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Ek teasing voice note bhejo jisme tum bata rahe ho milne par sabse pehle kya karoge.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Abhi apni sabse killer "dekhne wali" nazar wali photo bhejo.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Mujhe ek aisa message likho jo padhte hi mera chehra laal ho jaaye.'),
  TDCard(TDType.dare, TDTier.flirty,
      '30 second ki video bhejo jisme tum apne us andaaz mein "I miss you" kah rahe ho jo sirf mera hai.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Apne honth par ungli rakh kar ek shararati photo bhejo.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Meri kaunsi cheez tumhe sabse zyada attract karti hai — woh dekhte hue, bol kar record karo.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Abhi apni body language se ek "aa jao mere paas" wali photo banao aur bhejo.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Mujhe woh ek harkat dikhao (video) jo tum jaante ho mujhe bechain kar degi.'),
  TDCard(TDType.dare, TDTier.flirty,
      'Apni awaaz mein ek line bolo jo bilkul "tum mere ho" wale andaaz mein ho.'),

  // ─────────────────────────── DARES · SPICY ────────────────────────────
  TDCard(TDType.dare, TDTier.spicy,
      'Abhi ek mood wali photo bhejo (jitna comfortable ho) — sirf mere liye, kisi aur ke liye nahi.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Apni halki awaaz mein woh batao jo tum aaj raat mere saath karna chahte the — bina rukke record karo.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Mujhe woh jagah dikhao ya describe karo jahaan tum sabse pehle mera kiss chahte ho.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Ek voice note bhejo jisme tum apni ek fantasy sirf lafzon mein poori kar rahe ho.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Lights halki karke apni ek mood wali photo bhejo (jitna chaho, utna hi).'),
  TDCard(TDType.dare, TDTier.spicy,
      'Mujhe ek message likho jo bilkul tonight ke liye tumhara pura plan ho.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Whisper wali awaaz mein "good night" bolo aise jaise main bilkul paas hoon — record karke bhejo.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Woh dress ya look jo tum jaante ho mujhe pagal karta hai — usme ek photo bhejo (jitna comfortable ho).'),
  TDCard(TDType.dare, TDTier.spicy,
      'Apni ek bold khwahish abhi poore detail mein likho jo sirf mere saath poori karni hai.'),
  TDCard(TDType.dare, TDTier.spicy,
      'Apne sabse soft touch wali jagah par haath rakh kar socho main hoon — phir batao kaisa laga.'),
];
