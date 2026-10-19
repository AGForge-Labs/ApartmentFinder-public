/// Prefer the delivery ZIPs without hiding property exceptions or changing catalog order within a group.
public enum FinderCommunityOrder {
    public static func ordered(_ communities: [Community]) -> [Community] {
        let preferredZIPs: Set<String> = ["89113", "89148"]
        return communities.filter { preferredZIPs.contains($0.zip) }
            + communities.filter { !preferredZIPs.contains($0.zip) }
    }
}
