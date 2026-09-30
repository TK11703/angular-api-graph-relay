using Microsoft.Graph.Models;
using Poc.Api.Models;

namespace Poc.Api.Infrastructure;

/// <summary>Projects Graph entities onto the API's own DTOs so Graph types never leak to the client.</summary>
internal static class GraphMappings
{
    internal static readonly string[] ProfileSelect =
    [
        "id", "displayName", "givenName", "surname", "userPrincipalName", "mail",
        "jobTitle", "department", "officeLocation", "mobilePhone", "preferredLanguage"
    ];

    internal static UserProfile ToProfile(this User user) => new(
        user.Id,
        user.DisplayName,
        user.GivenName,
        user.Surname,
        user.UserPrincipalName,
        user.Mail,
        user.JobTitle,
        user.Department,
        user.OfficeLocation,
        user.MobilePhone,
        user.PreferredLanguage);

    internal static IReadOnlyList<DirectoryGroup> ToGroups(this DirectoryObjectCollectionResponse? response) =>
        response?.Value?
            .OfType<Group>()
            .Select(g => new DirectoryGroup(g.Id, g.DisplayName, g.Description))
            .ToArray() ?? [];
}
