defmodule ElectricPlug.Revocation do
  @moduledoc """
  What happens when access a person had through a share, a group or a role ends.

    * `revoke/2`: for a subject (a person, or a person and a record), the shapes they hold:
      - their cached `where` clause is discarded, so the next poll re-derives it from the authority
        as it is now;
      - a long poll already waiting for them is ended with the answer a revoked reader gets, and
        delivers no row it was holding;
      - their joins to channels for the record (presence, awareness) are closed.
      It answers how many of each it cut;
    * `watching/1`: the changes that call it: a host names the authority changes (a grant revoked, a
      group member removed, a role revoked) that call `revoke/2`. Syndikos's reach notifications are
      the usual caller.

  Only suspension cut a person off before; a share, a group membership or a role lasted up to a
  cache's age (about twenty-five seconds) and a presence roster until the socket reconnected.

  Designed and not yet built: each function refuses as not built until it is
  (`ElectricPlug.Examples`, a worked example each).
  """
  use VStack.Design.Stub.Module,
    functions: [revoke: 2, watching: 1],
    description:
      "Cutting a person off a stream the moment their access ends: their cached shape filters flushed, their waiting long polls ended and their channel joins closed, without waiting for a cache to expire or a socket to reconnect."
end
