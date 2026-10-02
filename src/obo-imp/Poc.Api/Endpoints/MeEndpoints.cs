using System.Security.Claims;
using Microsoft.Graph;
using Microsoft.Identity.Web;
using Poc.Api.Authorization;
using Poc.Api.Infrastructure;
using Poc.Api.Models;

namespace Poc.Api.Endpoints;

public static class MeEndpoints
{
    public static RouteGroupBuilder MapMeEndpoints(this RouteGroupBuilder group)
    {
        var me = group.MapGroup("/me").WithTags("Me");

        // Token-only view: lets the SPA decide whether to show the admin features.
        me.MapGet("/context", (ClaimsPrincipal user) =>
        {
            // Read the same claim type the authorization policies use, so the two cannot drift.
            var roleClaimType = (user.Identity as ClaimsIdentity)?.RoleClaimType ?? ClaimTypes.Role;
            var roles = user.FindAll(roleClaimType).Select(c => c.Value).ToArray();
            var scopes = (user.FindFirst(ClaimConstants.Scp) ?? user.FindFirst(ClaimConstants.Scope))
                ?.Value.Split(' ', StringSplitOptions.RemoveEmptyEntries) ?? [];

            return Results.Ok(new SignedInUser(
                user.GetObjectId(),
                user.GetTenantId(),
                user.GetDisplayName(),
                user.FindFirst(ClaimConstants.PreferredUserName)?.Value,
                roles.Contains(Policies.ApplicationAdminRole, StringComparer.OrdinalIgnoreCase),
                roles,
                scopes));
        })
        .WithName("GetMyContext");

        // Addressed by object id rather than /me so it also works with app-only (managed identity) tokens.
        me.MapGet("/", async (ClaimsPrincipal principal, GraphServiceClient graph, CancellationToken ct) =>
        {
            var user = await graph.Users[principal.GetObjectId()].GetAsync(
                r => r.QueryParameters.Select = GraphMappings.ProfileSelect, ct);

            return user is null ? Results.NotFound() : Results.Ok(user.ToProfile());
        })
        .WithName("GetMyProfile");

        me.MapGet("/groups", async (ClaimsPrincipal principal, GraphServiceClient graph, CancellationToken ct) =>
        {
            var memberOf = await graph.Users[principal.GetObjectId()].MemberOf.GetAsync(
                r => r.QueryParameters.Top = 50, ct);

            return Results.Ok(memberOf.ToGroups());
        })
        .WithName("GetMyGroups");

        return group;
    }
}
