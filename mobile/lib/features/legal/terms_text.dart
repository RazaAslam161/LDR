/// The terms, as a const string.
///
/// Not a WebView and not a URL. A link would open Chrome, which throws the user
/// out of an app whose whole launcher identity is a cover — and it would fail
/// on the plane, on a dead connection, and on the one screen that must work
/// before anything else does, since the gate stands in front of the app.
const milesTermsVersion = 1;

/// Shown in the header so somebody can tell two versions apart without
/// reading both.
const milesTermsUpdated = '16 August 2026';

/// Where the privacy policy is published.
///
/// Vercel project `miles-legal`, deployed from `web/`. It replaced an r2.dev
/// URL — that host is Cloudflare's rate-limited development domain, which their
/// own docs say not to build on, and it was serving one page while the other
/// four 404'd.
///
/// All seven pages sit in one directory and link to each other with relative
/// hrefs, so this base must not be split across hosts. Empty would mean "not
/// published", and the About card says so rather than opening a dead page.
const milesPrivacyPolicyUrl =
    'https://miles-legal.vercel.app/privacy-policy.html';

/// The Child Safety Standards, same host as the privacy policy.
///
/// Play blocks publishing a social/UGC app without this document, and it was
/// written and hosted before anything in the app pointed at it — so a reviewer
/// handed the Console URL could read it and a user could not find it at all.
const milesCsaeUrl = 'https://miles-legal.vercel.app/csae.html';

/// The vulnerability disclosure policy, same host again.
///
/// A researcher who finds something in a sideloaded APK has no other way to
/// reach us: there is no issue tracker, no store reply thread that carries a
/// technical report, and nothing in the app said where to write. The page is
/// the human half; `/.well-known/security.txt` on the same host is the
/// machine-readable half that scanners and disclosure platforms look for.
///
/// A URL rather than a bundled screen, for the same reason [milesCsaeUrl] is:
/// the audience is someone reading about the app, not necessarily someone
/// holding a phone with it installed.
const milesSecurityUrl = 'https://miles-legal.vercel.app/security.html';

/// Whether the Terms are complete enough to put in front of a user.
///
/// Both of these are the owner's to fill. Until they are, the gate still works
/// — the document is the agreement, not the address — but a release must not
/// ship without them, and a test asserts that rather than trusting anyone to
/// remember.
bool get milesTermsHasContact =>
    milesContactEmail.isNotEmpty && milesPrivacyPolicyUrl.isNotEmpty;

/// Left as a placeholder deliberately. A support address that does not receive
/// mail is worse than one the reader can see has not been filled in — and the
/// same token appears in the privacy policy, so both get answered at once.
/// Empty until the owner has one. A literal `{{CONTACT_EMAIL}}` was being
/// rendered under "12. CONTACT" to every user the gate stopped — asking people
/// to agree to a contract whose contact method was an unfilled template token.
///
/// The body no longer interpolates it at all: [milesTermsBody] is a `const`, so
/// anything conditional in it is a compile error, and a document that changes
/// shape depending on a constant is worse than one that points at the store
/// listing. This exists so [milesTermsHasContact] can flag the gap.
const milesContactEmail = 'Razaaslam3210@gmail.com';

const milesTermsBody = '''
Miles is a private app for two people. These terms are the agreement between
you and whoever runs it. They are short, and they are written to be true rather
than to sound reassuring.

1. YOU MUST BE 18

Miles is for adults. You must be 18 or older to use it. If you are under 18,
you may not create an account, and an account found to belong to a minor is
closed.

2. TWO PEOPLE, BY INVITATION

An account pairs with exactly one other account. You choose who; nobody is
matched to you, and there is no directory, no discovery and no way for a
stranger to reach you inside the app.

3. WHAT YOU MAY NOT SEND

Everything you put into Miles goes to your partner or into your own private
vault — never to a stranger, and never onto a public feed. You are responsible
for what you send. You may not use Miles to send, store or request:

  - sexual content involving anyone under 18, in any form, real or generated.
    There is no exception to this and no context that changes it;
  - intimate images of anyone who did not agree to them being shared, including
    a former partner, and including images that were taken with consent but
    shared without it;
  - images of any identifiable person taken without their knowledge in a place
    where they expected privacy;
  - threats, stalking, coercion, or a sustained campaign of contact aimed at
    frightening or wearing someone down;
  - content that is illegal where either of you is;
  - anything that impersonates another person, or that is sent to deceive
    someone about who you are;
  - malware, or attempts to break, overload or reverse the service.

Consent between two adults is assumed for what the two of you send each other.
It is not assumed for anything involving a third person.

4. WHAT WE CAN AND CANNOT SEE

This decides what enforcement is even possible, so it is stated plainly.

Some of Miles is end-to-end encrypted: Memory Threads, the text of Wish Jar
entries, and files you put in the private vault are encrypted on your phone
before they leave it, and the server stores ciphertext it cannot open. Nobody
operating the service can read those out of the database.

That is not the same as a promise they can never be read, and the difference is
yours to know. So that reinstalling the app does not destroy your history, Miles
keeps a sealed copy of your encryption key on the server. The seal is derived
from your account password — the same password the sign-in service is sent every
time you sign in — so anyone who has that password can open it. The privacy
policy sets out that trade, and the narrower limits around it, in sections 2
and 3.

The rest is not encrypted from us at all. Chat text, photos, videos, voice
notes, documents, location, cycle logs, profile details, and notes you type into
the vault are stored so that the operator of the database could read them. They
are protected by per-row access rules and private storage so that only you and
your partner can fetch them through the app — but they are not protected from
us. The privacy policy sets this out in full.

So enforcement here does not work the way it does on a public network. Nothing
is scanned, nothing is proactively reviewed, and there is no moderation queue
watching what two people send each other. Action is taken when somebody reports
it, and it is taken against the ACCOUNT — suspension or closure — rather than
against a particular message.

5. REPORTING

You can report your partner, any single message, and any item in the Gallery —
and, before you are paired with anybody, the app itself. Report lives in three
places:

  - Settings > Safety > Report a problem;
  - the menu at the top of Chat, and the toolbar that appears when you hold a
    message;
  - the toolbar that appears when you hold an item in the Gallery.

A report records who, when and why, plus an id for the item — never a copy of
it. Where the item is one of the encrypted kinds in section 4, there is nothing
anyone here could open anyway. If something specific needs to be acted on,
describe it in the note.

Nothing is kept on your phone afterwards, and there is no screen anywhere that
lists the reports you have filed. That is deliberate: on a handset the person
being reported may pick up, such a list would be the most dangerous thing this
app could show. You will not be told what happened either.

Reports about child sexual abuse material are treated as the most serious
category and may be passed to law enforcement along with the account details
attached to them.

Filing a deliberately false report to get someone's account closed is itself a
reason to close yours.

6. PAUSING CONTACT

Settings > Safety > Pause notifications stops your partner's Reaches and nudges
from notifying this phone, and drops an incoming call rather than ringing it,
for an hour, eight hours, a day, or until you turn it back on.

It is silent. Your partner is not told, and there is nothing on their side that
shows it. Their messages still send and still arrive; you simply see them when
you open the app rather than being interrupted. Nothing is deleted and the
relationship in the app is not ended. You can lift it at any time.

Two limits, said out loud, because a safety feature that is oversold is worse
than one that is described. It pauses being NOTIFIED, not arrival: with the app
open in front of you, a Reach still appears on screen. And a call can still post
a notification to this phone while the pause is on — opening it neither rings
nor connects the call, but the notification itself is not suppressed.

If you are in danger, this app is not a substitute for emergency services.

7. IF YOU BREAK THESE TERMS

An account that is used for anything in section 3 can be suspended or closed,
without notice where the content is illegal or someone is at risk. Where there
is a judgement to make, we would rather ask first — but for material involving
minors or non-consensual imagery there is no warning step.

Closing an account does not delete your partner's copy of what you already sent
them, and it does not delete anything already stored on their phone.

8. YOUR OWN ACCOUNT

You can delete your account at any time from Settings > Account. That erases
your data as described in the privacy policy. The sealed copy of your encryption
key is deleted along with the account, so once your phone's copy is gone too,
anything encrypted under it is unrecoverable by anybody, including us.

9. NO WARRANTY

Miles is provided as it is. It can lose messages, fail to deliver a call, or be
unavailable. Do not rely on it as the only way anyone can reach you.

10. CHANGES

If these terms change in a way that matters, you will be asked to accept the
new version before continuing. The version you accepted, and when, is recorded.

11. PRIVACY

The privacy policy is a separate document and forms part of this agreement. It
lists what is collected, what is encrypted, who else touches the data, and how
long any of it survives.

12. CONTACT

Razaaslam3210@gmail.com
''';
