import { util } from '@aws-appsync/utils';

const WEEK_SECONDS = 7 * 24 * 60 * 60;

/** Creates a 6-character invite code for the caller, valid for a week. */
export function request(ctx) {
  const code = util.autoId().split('-').join('').substring(0, 6).toUpperCase();
  const now = util.time.nowISO8601();
  const expires = util.time.nowEpochSeconds() + WEEK_SECONDS;
  return {
    operation: 'PutItem',
    key: util.dynamodb.toMapValues({ code }),
    attributeValues: util.dynamodb.toMapValues({
      ownerId: ctx.identity.sub,
      ownerName: ctx.args.ownerName,
      expiresAt: util.time.epochMilliSecondsToISO8601(expires * 1000),
      ttl: expires,
      createdAt: now,
      updatedAt: now,
    }),
    condition: { expression: 'attribute_not_exists(code)' },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
