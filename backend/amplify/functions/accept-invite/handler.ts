import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DeleteCommand, DynamoDBDocumentClient, GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import type { Schema } from '../../data/resource';

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));

/**
 * Redeems an invite code: creates a Share letting the caller read the inviter's data, then deletes
 * the code. Needs two tables, so it's a Lambda rather than a JS resolver.
 */
export const handler: Schema['acceptInvite']['functionHandler'] = async (event) => {
  const viewerId = (event.identity as { sub?: string } | null)?.sub;
  if (!viewerId) throw new Error('Unauthorized');

  const code = event.arguments.code.trim().toUpperCase();
  const { Item: invite } = await db.send(new GetCommand({ TableName: process.env.INVITE_TABLE, Key: { code } }));
  if (!invite || Date.parse(invite.expiresAt) < Date.now()) {
    throw new Error('That invite code is invalid or has expired.');
  }
  if (invite.ownerId === viewerId) {
    throw new Error("That's your own invite code. Send it to your partner.");
  }

  const now = new Date().toISOString();
  const share = {
    ownerId: invite.ownerId as string,
    viewerId,
    ownerName: (invite.ownerName as string | undefined) ?? null,
    viewerName: event.arguments.viewerName,
    createdAt: now,
    updatedAt: now,
    __typename: 'Share',
  };
  await db.send(new PutCommand({ TableName: process.env.SHARE_TABLE, Item: share }));
  await db.send(new DeleteCommand({ TableName: process.env.INVITE_TABLE, Key: { code } }));
  return share;
};
