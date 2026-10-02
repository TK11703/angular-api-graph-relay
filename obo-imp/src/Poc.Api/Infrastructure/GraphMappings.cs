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

    internal static User ToGraphPatch(this UserUpdateRequest update)
    {
        var user = new User { DisplayName = update.DisplayName.Trim() };

        Set(user, "givenName", update.GivenName, v => user.GivenName = v);
        Set(user, "surname", update.Surname, v => user.Surname = v);
        Set(user, "jobTitle", update.JobTitle, v => user.JobTitle = v);
        Set(user, "department", update.Department, v => user.Department = v);
        Set(user, "officeLocation", update.OfficeLocation, v => user.OfficeLocation = v);
        Set(user, "mobilePhone", update.MobilePhone, v => user.MobilePhone = v);

        return user;
    }

    // The Graph serializer skips null properties, so clearing a value has to go through AdditionalData.
    private static void Set(User user, string name, string? value, Action<string> assign)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            user.AdditionalData[name] = null!;
        }
        else
        {
            assign(value.Trim());
        }
    }

    internal static IReadOnlyList<DirectoryGroup> ToGroups(this DirectoryObjectCollectionResponse? response) =>
        response?.Value?
            .OfType<Group>()
            .Select(g => new DirectoryGroup(g.Id, g.DisplayName, g.Description))
            .ToArray() ?? [];
}
