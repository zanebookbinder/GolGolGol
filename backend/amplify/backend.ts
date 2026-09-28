import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import { data } from './data/resource';
import { acceptInvite } from './functions/accept-invite/resource';

const backend = defineBackend({ auth, data, acceptInvite });

const { tables, cfnResources } = backend.data.resources;
const inviteLambda = backend.acceptInvite.resources.lambda;

tables['Invite'].grantReadWriteData(inviteLambda);
tables['Share'].grantWriteData(inviteLambda);
backend.acceptInvite.addEnvironment('INVITE_TABLE', tables['Invite'].tableName);
backend.acceptInvite.addEnvironment('SHARE_TABLE', tables['Share'].tableName);

// Sign in once per iPhone: the refresh token (which the Watch also uses) lasts a year instead of 30 days.
const { cfnUserPoolClient } = backend.auth.resources.cfnResources;
cfnUserPoolClient.refreshTokenValidity = 365;
cfnUserPoolClient.tokenValidityUnits = { refreshToken: 'days' };

// Expired invite codes delete themselves.
cfnResources.amplifyDynamoDbTables['Invite'].timeToLiveAttribute = { attributeName: 'ttl', enabled: true };
