import 'package:miles/core/services/server_clock.dart';

/// The words on the re-link screen.
///
/// PUBLIC DOMAIN ONLY — every entry is by an author long out of copyright, a
/// classical source, or a pre-1929 English text (Tagore's and Gibran's own
/// English editions, Keller's 1903 autobiography, FitzGerald's 1859 Khayyam).
/// Modern translations of old poets are themselves copyrighted, which is why
/// there is no Rumi here however well he would fit. No song lyrics, ever.
/// Attribution is shown with every quote; nothing here is app-authored
/// sentiment beyond the choosing.
///
/// The pool follows the love-notes rules: warm, plain, never suggestive, and
/// no real names — `unlink_quotes_pool_test` enforces the shape.
const List<({String text, String author})> unlinkQuotePool = [
  (text: 'Whatever our souls are made of, his and mine are the same.', author: 'Emily Brontë'),
  (text: 'I have loved none but you.', author: 'Jane Austen'),
  (text: 'You pierce my soul. I am half agony, half hope.', author: 'Jane Austen'),
  (text: 'My true love hath my heart, and I have his.', author: 'Philip Sidney'),
  (text: 'Love is not love which alters when it alteration finds.', author: 'William Shakespeare'),
  (text: 'Doubt thou the stars are fire, but never doubt I love.', author: 'William Shakespeare'),
  (text: 'Love comforteth like sunshine after rain.', author: 'William Shakespeare'),
  (text: 'Love sought is good, but given unsought is better.', author: 'William Shakespeare'),
  (text: 'They do not love that do not show their love.', author: 'William Shakespeare'),
  (text: 'The course of true love never did run smooth.', author: 'William Shakespeare'),
  (text: 'Love looks not with the eyes, but with the mind.', author: 'William Shakespeare'),
  (text: 'My bounty is as boundless as the sea, my love as deep.', author: 'William Shakespeare'),
  (text: 'One half of me is yours, the other half yours.', author: 'William Shakespeare'),
  (text: 'I would not wish any companion in the world but you.', author: 'William Shakespeare'),
  (text: 'My heart is ever at your service.', author: 'William Shakespeare'),
  (text: 'I love thee to the depth and breadth and height my soul can reach.', author: 'Elizabeth Barrett Browning'),
  (text: 'How do I love thee? Let me count the ways.', author: 'Elizabeth Barrett Browning'),
  (text: "If thou must love me, let it be for love's sake only.", author: 'Elizabeth Barrett Browning'),
  (text: 'Grow old along with me! The best is yet to be.', author: 'Robert Browning'),
  (text: 'Take away love and our earth is a tomb.', author: 'Robert Browning'),
  (text: "I am my beloved's, and my beloved is mine.", author: 'Song of Solomon'),
  (text: 'Love is strong as death.', author: 'Song of Solomon'),
  (text: 'Many waters cannot quench love, neither can the floods drown it.', author: 'Song of Solomon'),
  (text: 'Whither thou goest, I will go.', author: 'Book of Ruth'),
  (text: 'There is no remedy for love but to love more.', author: 'Henry David Thoreau'),
  (text: 'Love is the only gold.', author: 'Alfred, Lord Tennyson'),
  (text: "'Tis better to have loved and lost than never to have loved at all.", author: 'Alfred, Lord Tennyson'),
  (text: 'Come live with me and be my love.', author: 'Christopher Marlowe'),
  (text: 'The fountains mingle with the river, and the rivers with the ocean.', author: 'Percy Bysshe Shelley'),
  (text: 'All things by a law divine in one spirit meet and mingle.', author: 'Percy Bysshe Shelley'),
  (text: 'One word frees us of all the weight and pain of life: that word is love.', author: 'Sophocles'),
  (text: 'Love is composed of a single soul inhabiting two bodies.', author: 'Aristotle'),
  (text: 'At the touch of love everyone becomes a poet.', author: 'Plato'),
  (text: 'Love conquers all things; let us too surrender to love.', author: 'Virgil'),
  (text: 'Love and you shall be loved.', author: 'Ralph Waldo Emerson'),
  (text: 'Two souls with but a single thought, two hearts that beat as one.', author: 'Friedrich Halm'),
  (text: 'Love is friendship set on fire.', author: 'Jeremy Taylor'),
  (text: 'Absence sharpens love, presence strengthens it.', author: 'Thomas Fuller'),
  (text: 'Life is the flower for which love is the honey.', author: 'Victor Hugo'),
  (text: 'The supreme happiness of life is the conviction that we are loved.', author: 'Victor Hugo'),
  (text: 'Love is the poetry of the senses.', author: 'Honoré de Balzac'),
  (text: 'The heart has its reasons which reason knows nothing of.', author: 'Blaise Pascal'),
  (text: 'In dreams and in love there are no impossibilities.', author: 'János Arany'),
  (text: 'Who, being loved, is poor?', author: 'Oscar Wilde'),
  (text: 'Keep love in your heart. A life without it is like a sunless garden.', author: 'Oscar Wilde'),
  (text: 'You are always new. The last of your kisses was ever the sweetest.', author: 'John Keats'),
  (text: 'Love does not dominate; it cultivates.', author: 'Johann Wolfgang von Goethe'),
  (text: 'We are shaped and fashioned by what we love.', author: 'Johann Wolfgang von Goethe'),
  (text: 'Love is heaven, and heaven is love.', author: 'Walter Scott'),
  (text: 'Unable are the loved to die, for love is immortality.', author: 'Emily Dickinson'),
  (text: 'That love is all there is, is all we know of love.', author: 'Emily Dickinson'),
  (text: 'Love is an endless mystery, for it has nothing else to explain it.', author: 'Rabindranath Tagore'),
  (text: 'I seem to have loved you in numberless forms, numberless times.', author: 'Rabindranath Tagore'),
  (text: 'Let there be spaces in your togetherness.', author: 'Kahlil Gibran'),
  (text: 'Love possesses not, nor would it be possessed.', author: 'Kahlil Gibran'),
  (text: 'She walks in beauty, like the night.', author: 'Lord Byron'),
  (text: 'There is no instinct like that of the heart.', author: 'Lord Byron'),
  (text: 'Love understands love; it needs no talk.', author: 'Frances Havergal'),
  (text: 'A jug of wine, a loaf of bread — and thou.', author: 'Omar Khayyam'),
  (text: 'Love is like a beautiful flower which I may not touch, but whose fragrance makes the garden a place of delight just the same.', author: 'Helen Keller'),
  (text: 'Love is space and time measured by the heart.', author: 'Marcel Proust'),
  (text: 'It is not a lack of love, but a lack of friendship that makes unhappy marriages.', author: 'Friedrich Nietzsche'),
  (text: 'There is always some madness in love. But there is also always some reason in madness.', author: 'Friedrich Nietzsche'),
  (text: 'Love is the emblem of eternity.', author: 'Madame de Staël'),
  (text: 'To love deeply in one direction makes us more loving in all others.', author: 'Anne-Sophie Swetchine'),
  (text: 'We loved with a love that was more than love.', author: 'Edgar Allan Poe'),
  (text: 'Love, and a cough, cannot be hid.', author: 'George Herbert'),
  (text: 'The sound of a kiss is not so loud as that of a cannon, but its echo lasts a great deal longer.', author: 'Oliver Wendell Holmes'),
  (text: 'A life without love is like a year without summer.', author: 'Swedish proverb'),
  (text: 'Where love is, there is no darkness.', author: 'Burundian proverb'),
];

/// Today's quote — the SAME on both phones.
///
/// Deterministic from the server-relative UTC date, the promptForDay pattern:
/// two handsets in different timezones (this couple's whole premise) must
/// never disagree about which words are on the screen they are both living
/// with this week.
({String text, String author}) unlinkQuoteForDay([DateTime? when]) {
  final utc = (when ?? ServerClock.now()).toUtc();
  final dayOfYear =
      utc.difference(DateTime.utc(utc.year)).inDays;
  return unlinkQuotePool[dayOfYear % unlinkQuotePool.length];
}
