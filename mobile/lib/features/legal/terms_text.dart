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

/// Where the privacy policy is published. `docs/legal/privacy-policy.md` and
/// `web/privacy-policy.html` exist; nothing hosts them yet, and inventing a URL
/// here would ship a link that 404s. Empty means "not published": the About
/// card says so instead of opening a dead page.
const milesPrivacyPolicyUrl =
    'https://pub-c97f0d4f49074dc3b7bdfe01521b7745.r2.dev/privacy-policy.html';

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

Everything in Miles is sent by one of you to the other. You are responsible for
what you send. You may not use Miles to send, store or request:

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

Some of Miles is end-to-end encrypted: Memory Threads, the Closer private
vault, and Wish Jar entries are encrypted on your phone with a key the server
never holds. Those cannot be read by anyone operating the service, and no
report, warrant or request changes that.

The rest is not. Chat text, photos, videos, voice notes, documents, location,
cycle logs and profile details are stored so that the operator of the database
could read them. They are protected by per-row access rules and private storage
so that only you and your partner can fetch them through the app — but they are
not protected from us. The privacy policy sets this out in full.

So enforcement here does not work the way it does on a public network. Nothing
is scanned, nothing is proactively reviewed, and there is no moderation queue
watching what two people send each other. Action is taken when somebody reports
it, and it is taken against the ACCOUNT — suspension or closure — rather than
against a particular message.

5. REPORTING

Anything in the app can be reported. Report lives in three places:

  - Settings > Safety > Report a problem;
  - the menu at the top of Chat, and the toolbar that appears when you hold a
    message;
  - the toolbar that appears when you hold an item in the Gallery.

A report records who, when and why. It does not attach the message or the
photo — see section 4 for why that would not help. If something specific needs
to be acted on, describe it in the note.

Reports about child sexual abuse material are treated as the most serious
category and may be passed to law enforcement along with the account details
attached to them.

Filing a deliberately false report to get someone's account closed is itself a
reason to close yours.

6. PAUSING CONTACT

Settings > Safety > Pause notifications stops your partner's messages, calls,
Reaches and nudges from reaching this phone, for an hour, eight hours, a day,
or until you turn it back on.

It is silent. Your partner is not told, and there is nothing on their side that
shows it. Their messages still send and still arrive; you simply see them when
you open the app rather than being interrupted. Nothing is deleted and the
relationship in the app is not ended. You can lift it at any time.

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
your data as described in the privacy policy. Content that is encrypted under a
key held only on the phones is unrecoverable by anybody, including us, once the
key is gone.

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
