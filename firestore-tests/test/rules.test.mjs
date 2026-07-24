// Firestore security-rules tests for ../../firestore.rules.
//
// Deliberately a single file: `node --test` runs separate test files in
// parallel child processes, and all of them would share the one Firestore
// emulator instance, so concurrent clearFirestore() calls would race.
// Within a single file, node:test runs tests serially by default.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, it, before, after, beforeEach } from 'node:test';

import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';
import {
  doc,
  collection,
  getDoc,
  getDocs,
  setDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
} from 'firebase/firestore';

const rulesPath = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '../../firestore.rules',
);

const [host, portStr] = (process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:8080').split(':');

/** @type {import('@firebase/rules-unit-testing').RulesTestEnvironment} */
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-vibecount',
    firestore: {
      rules: readFileSync(rulesPath, 'utf8'),
      host,
      port: Number(portStr),
    },
  });
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const alice = () => testEnv.authenticatedContext('alice').firestore();
const bob = () => testEnv.authenticatedContext('bob').firestore();
const carol = () => testEnv.authenticatedContext('carol').firestore();
const anon = () => testEnv.unauthenticatedContext().firestore();

function validUserDoc(displayName = 'Alice') {
  return {
    displayName,
    latestDailyTokens: 0,
    latestMonthlyTokens: 0,
    lastUpdated: serverTimestamp(),
  };
}

// Runs `fn(db)` with security rules disabled, for seeding fixtures.
async function seed(fn) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await fn(ctx.firestore());
  });
}

async function seedUser(uid, displayName) {
  await seed((db) => setDoc(doc(db, `users/${uid}`), validUserDoc(displayName)));
}

async function seedInviteCode(code, uid) {
  await seed((db) =>
    setDoc(doc(db, `inviteCodes/${code}`), { uid, createdAt: serverTimestamp() }),
  );
}

async function seedFriendship(ownerUid, friendUid, inviteCode) {
  await seed((db) =>
    setDoc(doc(db, `users/${ownerUid}/friends/${friendUid}`), {
      inviteCode,
      addedAt: serverTimestamp(),
    }),
  );
}

// Valid Crockford-uppercase 16-char codes (charset [0-9A-HJKMNP-TV-Z]).
const VALID_CODE = 'ABCDEFGH23456789';
const ALICE_CODE = 'AAAA222233334444';
const BOB_CODE = 'BBBB222233334444';
const CAROL_CODE = 'CCCC222233334444';
const SEEDED_CODE = 'HJKMNPQRSTVWXYZ2';

// ---------------------------------------------------------------------------
// Unauthenticated access
// ---------------------------------------------------------------------------

describe('unauthenticated access', () => {
  it('denies get on /users/alice', async () => {
    await seedUser('alice', 'Alice');
    await assertFails(getDoc(doc(anon(), 'users/alice')));
  });

  it('denies writes to /users/alice', async () => {
    await assertFails(setDoc(doc(anon(), 'users/alice'), validUserDoc()));
  });

  it('denies list of /users', async () => {
    await seedUser('alice', 'Alice');
    await assertFails(getDocs(collection(anon(), 'users')));
  });

  it('denies get on an invite code', async () => {
    await seedInviteCode(SEEDED_CODE, 'alice');
    await assertFails(getDoc(doc(anon(), `inviteCodes/${SEEDED_CODE}`)));
  });
});

// ---------------------------------------------------------------------------
// /users — owner writes
// ---------------------------------------------------------------------------

describe('users: owner writes', () => {
  it('allows owner create with exactly the required well-formed fields', async () => {
    await assertSucceeds(setDoc(doc(alice(), 'users/alice'), validUserDoc()));
  });

  it('allows owner update with new non-negative ints', async () => {
    await seedUser('alice', 'Alice');
    await assertSucceeds(
      updateDoc(doc(alice(), 'users/alice'), {
        latestDailyTokens: 1234,
        latestMonthlyTokens: 56789,
        lastUpdated: serverTimestamp(),
      }),
    );
  });

  it('allows values exactly at the caps', async () => {
    await assertSucceeds(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestDailyTokens: 1_000_000_000_000,
        latestMonthlyTokens: 30_000_000_000_000,
      }),
    );
  });

  it('allows the optional cost fields when well-formed', async () => {
    await assertSucceeds(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestDailyCost: 1.25,
        latestMonthlyCost: 92.5,
      }),
    );
  });

  it('allows cost fields exactly at the cap', async () => {
    await assertSucceeds(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestDailyCost: 100_000_000,
        latestMonthlyCost: 100_000_000,
      }),
    );
  });
});

describe('users: malformed owner writes are denied', () => {
  it('denies create missing a field', async () => {
    const { lastUpdated, ...missing } = validUserDoc();
    await assertFails(setDoc(doc(alice(), 'users/alice'), missing));
  });

  it('denies create with an extra field', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), admin: true }),
    );
  });

  it('denies displayName as empty string', async () => {
    await assertFails(setDoc(doc(alice(), 'users/alice'), validUserDoc('')));
  });

  it('denies displayName longer than 50 chars', async () => {
    await assertFails(setDoc(doc(alice(), 'users/alice'), validUserDoc('x'.repeat(51))));
  });

  it('denies displayName of wrong type (number)', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), displayName: 42 }),
    );
  });

  it('denies negative latestDailyTokens', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), latestDailyTokens: -1 }),
    );
  });

  it('denies latestDailyTokens as string', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), latestDailyTokens: '0' }),
    );
  });

  it('denies negative latestMonthlyTokens', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), latestMonthlyTokens: -5 }),
    );
  });

  it('denies latestDailyTokens above the 1e12 cap', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestDailyTokens: 1_000_000_000_001,
      }),
    );
  });

  it('denies latestMonthlyTokens above the 3e13 cap', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestMonthlyTokens: 30_000_000_000_001,
      }),
    );
  });

  it('denies lastUpdated as string', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        lastUpdated: '2026-07-10T00:00:00Z',
      }),
    );
  });

  it('denies negative latestDailyCost', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), latestDailyCost: -0.01 }),
    );
  });

  it('denies latestMonthlyCost above the 1e8 cap', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), {
        ...validUserDoc(),
        latestMonthlyCost: 100_000_000.01,
      }),
    );
  });

  it('denies latestDailyCost of wrong type (string)', async () => {
    await assertFails(
      setDoc(doc(alice(), 'users/alice'), { ...validUserDoc(), latestDailyCost: '1.25' }),
    );
  });
});

// ---------------------------------------------------------------------------
// /users — cross-user writes, delete, list
// ---------------------------------------------------------------------------

describe('users: cross-user access', () => {
  it("denies alice creating bob's user doc", async () => {
    await assertFails(setDoc(doc(alice(), 'users/bob'), validUserDoc('Bob')));
  });

  it("denies alice updating bob's user doc", async () => {
    await seedUser('bob', 'Bob');
    await assertFails(
      updateDoc(doc(alice(), 'users/bob'), {
        latestDailyTokens: 1,
        lastUpdated: serverTimestamp(),
      }),
    );
  });

  it("denies alice deleting bob's user doc", async () => {
    await seedUser('bob', 'Bob');
    await assertFails(deleteDoc(doc(alice(), 'users/bob')));
  });

  it('allows alice to delete her own user doc', async () => {
    await seedUser('alice', 'Alice');
    await assertSucceeds(deleteDoc(doc(alice(), 'users/alice')));
  });

  it('denies list of /users even for a signed-in user', async () => {
    await seedUser('alice', 'Alice');
    await seedUser('bob', 'Bob');
    await assertFails(getDocs(collection(alice(), 'users')));
  });
});

// ---------------------------------------------------------------------------
// /inviteCodes
// ---------------------------------------------------------------------------

describe('inviteCodes', () => {
  it('allows alice to register a valid 16-char Crockford code for herself', async () => {
    await assertSucceeds(
      setDoc(doc(alice(), `inviteCodes/${VALID_CODE}`), {
        uid: 'alice',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it("denies alice registering a code that points at bob's uid", async () => {
    await assertFails(
      setDoc(doc(alice(), `inviteCodes/${VALID_CODE}`), {
        uid: 'bob',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('denies a lowercase code', async () => {
    await assertFails(
      setDoc(doc(alice(), 'inviteCodes/abcdefgh23456789'), {
        uid: 'alice',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it('denies an 8-char code', async () => {
    await assertFails(
      setDoc(doc(alice(), 'inviteCodes/ABCD2345'), {
        uid: 'alice',
        createdAt: serverTimestamp(),
      }),
    );
  });

  it("denies codes containing the excluded Crockford letters O, I, L, U", async () => {
    for (const letter of ['O', 'I', 'L', 'U']) {
      const code = `${letter}BCDEFGH23456789`;
      await assertFails(
        setDoc(doc(alice(), `inviteCodes/${code}`), {
          uid: 'alice',
          createdAt: serverTimestamp(),
        }),
      );
    }
  });

  it('denies create with an extra field', async () => {
    await assertFails(
      setDoc(doc(alice(), `inviteCodes/${VALID_CODE}`), {
        uid: 'alice',
        createdAt: serverTimestamp(),
        note: 'extra',
      }),
    );
  });

  it('denies updating an existing code (immutability), with and without merge', async () => {
    await seedInviteCode(SEEDED_CODE, 'alice');
    // Overwrite without merge (an update op, since the doc exists).
    await assertFails(
      setDoc(doc(alice(), `inviteCodes/${SEEDED_CODE}`), {
        uid: 'alice',
        createdAt: serverTimestamp(),
      }),
    );
    // Merge write.
    await assertFails(
      setDoc(
        doc(alice(), `inviteCodes/${SEEDED_CODE}`),
        { createdAt: serverTimestamp() },
        { merge: true },
      ),
    );
  });

  it('allows an authenticated point get of an existing code', async () => {
    await seedInviteCode(SEEDED_CODE, 'bob');
    await assertSucceeds(getDoc(doc(alice(), `inviteCodes/${SEEDED_CODE}`)));
  });

  it('allows an authenticated point get of a missing code', async () => {
    await assertSucceeds(getDoc(doc(alice(), 'inviteCodes/ZZZZ888877776666')));
  });

  it('denies list of /inviteCodes', async () => {
    await seedInviteCode(SEEDED_CODE, 'alice');
    await assertFails(getDocs(collection(alice(), 'inviteCodes')));
  });

  it('allows alice to delete her own code', async () => {
    await seedInviteCode(ALICE_CODE, 'alice');
    await assertSucceeds(deleteDoc(doc(alice(), `inviteCodes/${ALICE_CODE}`)));
  });

  it("denies alice deleting bob's code", async () => {
    await seedInviteCode(BOB_CODE, 'bob');
    await assertFails(deleteDoc(doc(alice(), `inviteCodes/${BOB_CODE}`)));
  });
});

// ---------------------------------------------------------------------------
// Friendship (/users/{uid}/friends/{friendUid})
// ---------------------------------------------------------------------------

describe('friendship', () => {
  // Common fixtures: user docs for alice/bob/carol and invite codes mapping
  // to bob and carol.
  async function seedPeople() {
    await seedUser('alice', 'Alice');
    await seedUser('bob', 'Bob');
    await seedUser('carol', 'Carol');
    await seedInviteCode(BOB_CODE, 'bob');
    await seedInviteCode(CAROL_CODE, 'carol');
  }

  function friendPayload(inviteCode) {
    return { inviteCode, addedAt: serverTimestamp() };
  }

  it("allows alice to add bob using bob's invite code", async () => {
    await seedPeople();
    await assertSucceeds(
      setDoc(doc(alice(), 'users/alice/friends/bob'), friendPayload(BOB_CODE)),
    );
  });

  it("allows alice to get /users/bob once the friendship exists", async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertSucceeds(getDoc(doc(alice(), 'users/bob')));
  });

  it('denies carol getting /users/bob without a friendship', async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertFails(getDoc(doc(carol(), 'users/bob')));
  });

  it("denies adding bob with a code that actually maps to carol", async () => {
    await seedPeople();
    await assertFails(
      setDoc(doc(alice(), 'users/alice/friends/bob'), friendPayload(CAROL_CODE)),
    );
  });

  it('denies adding a friend with a nonexistent invite code', async () => {
    await seedPeople();
    await assertFails(
      setDoc(doc(alice(), 'users/alice/friends/bob'), friendPayload('NQPE222233334444')),
    );
  });

  it('denies alice befriending herself, even with her own valid code', async () => {
    await seedPeople();
    await seedInviteCode(ALICE_CODE, 'alice');
    await assertFails(
      setDoc(doc(alice(), 'users/alice/friends/alice'), friendPayload(ALICE_CODE)),
    );
  });

  it("denies alice writing into bob's friends subcollection", async () => {
    await seedPeople();
    await seedInviteCode(ALICE_CODE, 'alice');
    await assertFails(
      setDoc(doc(alice(), 'users/bob/friends/alice'), friendPayload(ALICE_CODE)),
    );
  });

  it('denies a friends doc with extra fields', async () => {
    await seedPeople();
    await assertFails(
      setDoc(doc(alice(), 'users/alice/friends/bob'), {
        ...friendPayload(BOB_CODE),
        nickname: 'Bobby',
      }),
    );
  });

  it('denies updating an existing friends doc', async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertFails(
      updateDoc(doc(alice(), 'users/alice/friends/bob'), {
        addedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(
        doc(alice(), 'users/alice/friends/bob'),
        friendPayload(BOB_CODE),
        { merge: true },
      ),
    );
  });

  it('allows alice to list and read her own friends subcollection', async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertSucceeds(getDocs(collection(alice(), 'users/alice/friends')));
    await assertSucceeds(getDoc(doc(alice(), 'users/alice/friends/bob')));
  });

  it("denies bob reading alice's friends subcollection", async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertFails(getDocs(collection(bob(), 'users/alice/friends')));
    await assertFails(getDoc(doc(bob(), 'users/alice/friends/bob')));
  });

  it('allows alice to delete her own friends doc', async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertSucceeds(deleteDoc(doc(alice(), 'users/alice/friends/bob')));
  });

  it('denies alice getting /users/bob again after the friendship is removed', async () => {
    await seedPeople();
    await seedFriendship('alice', 'bob', BOB_CODE);
    await assertSucceeds(getDoc(doc(alice(), 'users/bob')));
    await assertSucceeds(deleteDoc(doc(alice(), 'users/alice/friends/bob')));
    await assertFails(getDoc(doc(alice(), 'users/bob')));
  });
});

// ---------------------------------------------------------------------------
// Catch-all
// ---------------------------------------------------------------------------

describe('catch-all', () => {
  it('denies authenticated reads of an unmatched collection', async () => {
    await seed((db) => setDoc(doc(db, 'randomCollection/doc'), { anything: true }));
    await assertFails(getDoc(doc(alice(), 'randomCollection/doc')));
  });

  it('denies authenticated writes to an unmatched collection', async () => {
    await assertFails(setDoc(doc(alice(), 'randomCollection/doc'), { anything: true }));
  });
});
