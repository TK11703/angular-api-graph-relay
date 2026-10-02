using Microsoft.AspNetCore.Mvc;
using Microsoft.Graph;
using Microsoft.Identity.Web;
using Poc.Api.Authorization;
using Poc.Api.Infrastructure;
using Poc.Api.Models;

namespace Poc.Api.Endpoints;

public static class UserEndpoints
{
    public static RouteGroupBuilder MapUserEndpoints(this RouteGroupBuilder group)
    {
        // Reads only need the default policy; writes additionally demand the ApplicationAdmin app role.
        var users = group.MapGroup("/users").WithTags("Users");

        users.MapGet("/properties", () => Results.Ok(new UserPropertyCatalogResponse(
            UserPropertyCatalog.Selectable,
            UserPropertyCatalog.Searched,
            UserPropertyCatalog.DefaultNames)))
        .WithName("GetUserProperties");

        users.MapGet("/", async ([AsParameters] UserSearchRequest request, GraphServiceClient graph, CancellationToken ct) =>
        {
            var fields = UserPropertyCatalog.Resolve(request.Select);

            var result = await graph.Users.GetAsync(r =>
            {
                // Both halves are safe to interpolate: the term is regex-constrained by validation and
                // the field names come from the catalog, never from the caller.
                if (!string.IsNullOrWhiteSpace(request.Search))
                {
                    r.QueryParameters.Search = UserPropertyCatalog.BuildSearchExpression(request.Search);
                }
                if (!string.IsNullOrWhiteSpace(request.Department))
                {
                    r.QueryParameters.Filter = UserPropertyCatalog.BuildDepartmentFilter(request.Department);
                }
                r.QueryParameters.Select = UserPropertyCatalog.GraphSelect(fields);
                r.QueryParameters.Orderby = ["displayName"];
                r.QueryParameters.Top = request.Top;
                r.QueryParameters.Count = true;
                r.Headers.Add("ConsistencyLevel", "eventual");
            }, ct);

            var matches = result?.Value?.Select(u => UserPropertyCatalog.Project(u, fields)).ToArray() ?? [];
            return Results.Ok(new UserSearchResponse(fields, matches));
        })
        .WithName("SearchUsers");

        users.MapGet("/{id}", async ([AsParameters] UserLookupRequest request, GraphServiceClient graph, CancellationToken ct) =>
        {
            var user = await graph.Users[request.Id].GetAsync(
                r => r.QueryParameters.Select = GraphMappings.ProfileSelect, ct);

            return user is null ? Results.NotFound() : Results.Ok(user.ToProfile());
        })
        .WithName("GetUserById");

        users.MapGet("/{id}/groups", async ([AsParameters] UserLookupRequest request, GraphServiceClient graph, CancellationToken ct) =>
        {
            var memberOf = await graph.Users[request.Id].MemberOf.GetAsync(
                r => r.QueryParameters.Top = 50, ct);

            return Results.Ok(memberOf.ToGroups());
        })
        .WithName("GetUserGroups");

        users.MapPatch("/{id}", async (
            [AsParameters] UserLookupRequest target,
            [FromBody] UserUpdateRequest update,
            GraphServiceClient graph,
            CancellationToken ct) =>
        {
            // Write scope is requested only for this call, so read-only OBO tokens stay read-only.
            // Ignored in managed-identity mode, where the identity's app roles apply instead.
            await graph.Users[target.Id].PatchAsync(
                update.ToGraphPatch(), r => r.Options.WithScopes(GraphScopes.UserWrite), ct);

            var user = await graph.Users[target.Id].GetAsync(
                r => r.QueryParameters.Select = GraphMappings.ProfileSelect, ct);

            return user is null ? Results.NotFound() : Results.Ok(user.ToProfile());
        })
        .RequireAuthorization(Policies.CanEditUsers)
        .WithName("UpdateUser");

        return group;
    }
}
