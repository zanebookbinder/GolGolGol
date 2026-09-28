import { defineAuth, secret } from '@aws-amplify/backend';

/**
 * Cognito user pool with the hosted UI. Email sign-in always works.
 *
 * Sign in with Apple is added when deployed with SIWA=1, after setting its secrets once:
 *   npx ampx sandbox secret set SIWA_CLIENT_ID    (your Services ID, e.g. com.zanebookbinder.goaltracker.signin)
 *   npx ampx sandbox secret set SIWA_TEAM_ID
 *   npx ampx sandbox secret set SIWA_KEY_ID
 *   npx ampx sandbox secret set SIWA_PRIVATE_KEY  (contents of the .p8 key)
 *   SIWA=1 npm run sandbox
 */
const withApple = process.env.SIWA === '1';

export const auth = defineAuth({
  loginWith: {
    email: true,
    externalProviders: {
      ...(withApple && {
        signInWithApple: {
          clientId: secret('SIWA_CLIENT_ID'),
          teamId: secret('SIWA_TEAM_ID'),
          keyId: secret('SIWA_KEY_ID'),
          privateKey: secret('SIWA_PRIVATE_KEY'),
        },
      }),
      callbackUrls: ['goaltracker://auth/'],
      logoutUrls: ['goaltracker://signout/'],
    },
  },
});
