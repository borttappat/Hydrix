/*
 * router-netlink.h: generic netlink helpers shared by router-netlink-poller.c
 * and router-stats-server.c (both libmnl).
 */
#ifndef ROUTER_NETLINK_H
#define ROUTER_NETLINK_H

#include <string.h>
#include <time.h>
#include <libmnl/libmnl.h>
#include <linux/genetlink.h>

/* libmnl's MNL_SOCKET_BUFFER_SIZE is min(pagesize, 8192): 4096 on 4K-page
 * systems. NL80211_CMD_GET_INTERFACE on a real card returns channel/width/
 * txpower/TXQ stats alongside the SSID, easily exceeding that, and a
 * WireGuard device dump grows with peer count. Netlink silently truncates
 * oversized reads, so use a larger explicit buffer everywhere. */
#define NL_BUF_SIZE 32768

#define NL_MAX_GROUPS 8

struct family_result {
    int id;
    /* Multicast groups the caller wants ids for (names in, ids out, -1 if
     * the family doesn't have that group). */
    int ngroups;
    const char *group_names[NL_MAX_GROUPS];
    int group_ids[NL_MAX_GROUPS];
};

static int family_group_cb(const struct nlattr *attr, void *data) {
    struct family_result *res = data;
    const char *name = NULL;
    int id = -1;
    struct nlattr *a;
    mnl_attr_for_each_nested(a, attr) {
        if (mnl_attr_get_type(a) == CTRL_ATTR_MCAST_GRP_NAME)
            name = mnl_attr_get_str(a);
        else if (mnl_attr_get_type(a) == CTRL_ATTR_MCAST_GRP_ID)
            id = (int)mnl_attr_get_u32(a);
    }
    for (int i = 0; name && i < res->ngroups; i++)
        if (!strcmp(name, res->group_names[i])) res->group_ids[i] = id;
    return MNL_CB_OK;
}

static int family_attr_cb(const struct nlattr *attr, void *data) {
    struct family_result *res = data;
    int type = mnl_attr_get_type(attr);
    if (type == CTRL_ATTR_FAMILY_ID) {
        if (mnl_attr_validate(attr, MNL_TYPE_U16) < 0) return MNL_CB_OK;
        res->id = mnl_attr_get_u16(attr);
    } else if (type == CTRL_ATTR_MCAST_GROUPS) {
        struct nlattr *grp;
        mnl_attr_for_each_nested(grp, attr) family_group_cb(grp, data);
    }
    return MNL_CB_OK;
}

static int family_msg_cb(const struct nlmsghdr *nlh, void *data) {
    mnl_attr_parse(nlh, sizeof(struct genlmsghdr), family_attr_cb, data);
    return MNL_CB_OK;
}

/* Resolves a genl family name ("nl80211", "wireguard") to its numeric id,
 * filling res->group_ids for any requested multicast groups. Returns -1 if
 * the family isn't registered (module not loaded): callers treat that as
 * "no data available", not fatal. */
static int resolve_family(struct mnl_socket *nl, const char *name, struct family_result *res) {
    char buf[NL_BUF_SIZE];
    unsigned int seq = time(NULL);
    unsigned int portid = mnl_socket_get_portid(nl);

    struct nlmsghdr *nlh = mnl_nlmsg_put_header(buf);
    nlh->nlmsg_type = GENL_ID_CTRL;
    nlh->nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    nlh->nlmsg_seq = seq;
    struct genlmsghdr *genl = mnl_nlmsg_put_extra_header(nlh, sizeof(*genl));
    genl->cmd = CTRL_CMD_GETFAMILY;
    genl->version = 1;
    mnl_attr_put_strz(nlh, CTRL_ATTR_FAMILY_NAME, name);

    res->id = -1;
    for (int i = 0; i < res->ngroups; i++) res->group_ids[i] = -1;
    if (mnl_socket_sendto(nl, nlh, nlh->nlmsg_len) < 0) return -1;

    int ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    while (ret > 0) {
        ret = mnl_cb_run(buf, ret, seq, portid, family_msg_cb, res);
        if (ret <= 0) break;
        ret = mnl_socket_recvfrom(nl, buf, sizeof(buf));
    }
    return res->id;
}

#endif
