import { a, defineData, type ClientSchema } from '@aws-amplify/backend';
import { acceptInvite } from '../functions/accept-invite/resource';

/**
 * Storage and API. Clients use the custom operations below rather than the generated model
 * operations:
 * - writes (`put*`, `upsert*`) check that `ownerId` is the caller, so partners are read-only;
 * - reads (`*For`) take an `ownerId` and pass only if it's the caller or a Share names the caller
 *   as viewer. The check runs in the resolver (`checkAccess.js`), not in the client.
 *
 * Enums are plain strings so the Swift client can map them without generated code.
 */
const schema = a.schema({
  User: a
    .model({
      ownerId: a.string().required(),
      displayName: a.string().required(),
      timeZone: a.string().required(),
    })
    .identifier(['ownerId'])
    .authorization((allow) => [allow.ownerDefinedIn('ownerId').identityClaim('sub')]),

  Goal: a
    .model({
      ownerId: a.string().required(),
      id: a.string().required(),
      type: a.string().required(),
      direction: a.string().required(),
      target: a.float().required(),
      unit: a.string().required(),
      active: a.boolean().required(),
      /** Weekday bitmask: bit 0 = Sunday … bit 6 = Saturday. */
      days: a.integer().required(),
      workoutMeasure: a.string(),
      changedAt: a.datetime().required(),
    })
    .identifier(['ownerId', 'id'])
    .authorization((allow) => [allow.ownerDefinedIn('ownerId').identityClaim('sub')]),

  /** Every raw reading. sk = date#type#metricId, so one prefix query returns a day, week, or month. */
  Metric: a
    .model({
      ownerId: a.string().required(),
      sk: a.string().required(),
      metricId: a.string().required(),
      date: a.date().required(),
      type: a.string().required(),
      source: a.string().required(),
      value: a.float().required(),
      recordedAt: a.datetime().required(),
      detail: a.json(),
    })
    .identifier(['ownerId', 'sk'])
    .authorization((allow) => [allow.ownerDefinedIn('ownerId').identityClaim('sub')]),

  /** Evaluated result per goal per day. sk = date#goalId. */
  DaySummary: a
    .model({
      ownerId: a.string().required(),
      sk: a.string().required(),
      date: a.date().required(),
      goalId: a.string().required(),
      goalType: a.string().required(),
      status: a.string().required(),
      value: a.float(),
      upperValue: a.float(),
      confidence: a.string().required(),
      changedAt: a.datetime().required(),
    })
    .identifier(['ownerId', 'sk'])
    .authorization((allow) => [allow.ownerDefinedIn('ownerId').identityClaim('sub')]),

  /** Lets viewerId read ownerId's records. Created only by acceptInvite. */
  Share: a
    .model({
      ownerId: a.string().required(),
      viewerId: a.string().required(),
      ownerName: a.string(),
      viewerName: a.string(),
    })
    .identifier(['ownerId', 'viewerId'])
    .authorization((allow) => [
      allow.ownerDefinedIn('ownerId').identityClaim('sub').to(['read', 'delete']),
      allow.ownerDefinedIn('viewerId').identityClaim('sub').to(['read', 'delete']),
    ]),

  /** Short code a partner enters to create a Share. Expires via DynamoDB TTL on `ttl`. */
  Invite: a
    .model({
      code: a.string().required(),
      ownerId: a.string().required(),
      ownerName: a.string(),
      expiresAt: a.datetime().required(),
      ttl: a.integer(),
    })
    .identifier(['code'])
    .authorization((allow) => [allow.ownerDefinedIn('ownerId').identityClaim('sub').to(['read', 'delete'])]),

  // MARK: Writes

  putUser: a
    .mutation()
    .arguments({ ownerId: a.string().required(), displayName: a.string().required(), timeZone: a.string().required() })
    .returns(a.ref('User'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('User'), entry: './resolvers/putOwned.js' })),

  upsertGoal: a
    .mutation()
    .arguments({
      ownerId: a.string().required(),
      id: a.string().required(),
      type: a.string().required(),
      direction: a.string().required(),
      target: a.float().required(),
      unit: a.string().required(),
      active: a.boolean().required(),
      days: a.integer().required(),
      workoutMeasure: a.string(),
      changedAt: a.datetime().required(),
    })
    .returns(a.ref('Goal'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('Goal'), entry: './resolvers/putOwned.js' })),

  putMetric: a
    .mutation()
    .arguments({
      ownerId: a.string().required(),
      sk: a.string().required(),
      metricId: a.string().required(),
      date: a.date().required(),
      type: a.string().required(),
      source: a.string().required(),
      value: a.float().required(),
      recordedAt: a.datetime().required(),
      detail: a.json(),
    })
    .returns(a.ref('Metric'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('Metric'), entry: './resolvers/putOwned.js' })),

  upsertDaySummary: a
    .mutation()
    .arguments({
      ownerId: a.string().required(),
      sk: a.string().required(),
      date: a.date().required(),
      goalId: a.string().required(),
      goalType: a.string().required(),
      status: a.string().required(),
      value: a.float(),
      upperValue: a.float(),
      confidence: a.string().required(),
      changedAt: a.datetime().required(),
    })
    .returns(a.ref('DaySummary'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('DaySummary'), entry: './resolvers/putOwned.js' })),

  // MARK: Reads (owner or shared viewer)

  goalsFor: a
    .query()
    .arguments({ ownerId: a.string().required() })
    .returns(a.ref('Goal').array())
    .authorization((allow) => [allow.authenticated()])
    .handler([
      a.handler.custom({ dataSource: a.ref('Share'), entry: './resolvers/checkAccess.js' }),
      a.handler.custom({ dataSource: a.ref('Goal'), entry: './resolvers/queryOwner.js' }),
    ]),

  daySummariesFor: a
    .query()
    .arguments({ ownerId: a.string().required(), from: a.string().required(), to: a.string().required() })
    .returns(a.ref('DaySummary').array())
    .authorization((allow) => [allow.authenticated()])
    .handler([
      a.handler.custom({ dataSource: a.ref('Share'), entry: './resolvers/checkAccess.js' }),
      a.handler.custom({ dataSource: a.ref('DaySummary'), entry: './resolvers/queryOwnerRange.js' }),
    ]),

  metricsFor: a
    .query()
    .arguments({ ownerId: a.string().required(), from: a.string().required(), to: a.string().required() })
    .returns(a.ref('Metric').array())
    .authorization((allow) => [allow.authenticated()])
    .handler([
      a.handler.custom({ dataSource: a.ref('Share'), entry: './resolvers/checkAccess.js' }),
      a.handler.custom({ dataSource: a.ref('Metric'), entry: './resolvers/queryOwnerRange.js' }),
    ]),

  // MARK: Sharing

  makeInvite: a
    .mutation()
    .arguments({ ownerName: a.string().required() })
    .returns(a.ref('Invite'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('Invite'), entry: './resolvers/createInvite.js' })),

  acceptInvite: a
    .mutation()
    .arguments({ code: a.string().required(), viewerName: a.string().required() })
    .returns(a.ref('Share'))
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.function(acceptInvite)),

  /** Live updates of an owner's DaySummaries, for the owner or a shared viewer. */
  onDaySummaryUpserted: a
    .subscription()
    .for(a.ref('upsertDaySummary'))
    .arguments({ ownerId: a.string().required() })
    .authorization((allow) => [allow.authenticated()])
    .handler(a.handler.custom({ dataSource: a.ref('Share'), entry: './resolvers/subscribeSummaries.js' })),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: 'userPool',
  },
});
