--[[
Problems with this:

-   Some keys trigger certain transformice actions
    that make us lose focus (opening the inventory, focusing the chat)

-   Since I had to replace < and > with their
    HTML entity counterparts and they take more than 1 character,
    you can sometimes see the unfinished entity, until it finally gets
    finished and gets replaced with < or >.

-   Fonts can be inconsistent in height, and we need to know the
    number of lines the whole screen can fit

-   Over 500 lines before the code even starts lol

-   If you click way too fast you might crash the room
    because runtime might exceed 40ms in 4 seconds
]]

code = [[struct group_info init_groups = { .usage = ATOMIC_INIT(2) };

struct group_info *groups_alloc(int gidsetsize){

	struct group_info *group_info;

	int nblocks;

	int i;


	nblocks = (gidsetsize + NGROUPS_PER_BLOCK - 1) / NGROUPS_PER_BLOCK;

	/* Make sure we always allocate at least one indirect block pointer */

	nblocks = nblocks ? : 1;

	group_info = kmalloc(sizeof(*group_info) + nblocks*sizeof(gid_t *), GFP_USER);

	if (!group_info)

		return NULL;

	group_info-&gt; ngroups = gidsetsize;

	group_info-&gt; nblocks = nblocks;

	atomic_set(&group_info-&gt; usage, 1);



	if (gidsetsize &lt;= NGROUPS_SMALL)

		group_info-&gt; blocks[0] = group_info-&gt; small_block;

	else {

		for (i = 0; i &lt; nblocks; i++) {

			gid_t *b;

			b = (void *)__get_free_page(GFP_USER);

			if (!b)

				goto out_undo_partial_alloc;

			group_info-&gt; blocks[i] = b;

		}

	}

	return group_info;



out_undo_partial_alloc:

	while (--i &gt; = 0) {

		free_page((unsigned long)group_info-&gt; blocks[i]);

	}

	kfree(group_info);

	return NULL;

}



EXPORT_SYMBOL(groups_alloc);



void groups_free(struct group_info *group_info)

{

	if (group_info-&gt; blocks[0] != group_info-&gt; small_block) {

		int i;

		for (i = 0; i &lt; group_info-&gt; nblocks; i++)

			free_page((unsigned long)group_info-&gt; blocks[i]);

	}

	kfree(group_info);

}



EXPORT_SYMBOL(groups_free);



/* export the group_info to a user-space array */

static int groups_to_user(gid_t __user *grouplist,

			  const struct group_info *group_info)

{

	int i;

	unsigned int count = group_info-&gt; ngroups;



	for (i = 0; i &lt; group_info-&gt; nblocks; i++) {

		unsigned int cp_count = min(NGROUPS_PER_BLOCK, count);

		unsigned int len = cp_count * sizeof(*grouplist);



		if (copy_to_user(grouplist, group_info-&gt; blocks[i], len))

			return -EFAULT;



		grouplist += NGROUPS_PER_BLOCK;

		count -= cp_count;

	}

	return 0;

}



/* fill a group_info from a user-space array - it must be allocated already */

static int groups_from_user(struct group_info *group_info,

    gid_t __user *grouplist)

{

	int i;

	unsigned int count = group_info-&gt; ngroups;



	for (i = 0; i &lt; group_info-&gt; nblocks; i++) {

		unsigned int cp_count = min(NGROUPS_PER_BLOCK, count);

		unsigned int len = cp_count * sizeof(*grouplist);



		if (copy_from_user(group_info-&gt; blocks[i], grouplist, len))

			return -EFAULT;



		grouplist += NGROUPS_PER_BLOCK;

		count -= cp_count;

	}

	return 0;

}



/* a simple Shell sort */

static void groups_sort(struct group_info *group_info)

{

	int base, max, stride;

	int gidsetsize = group_info-&gt; ngroups;



	for (stride = 1; stride &lt; gidsetsize; stride = 3 * stride + 1)

		; /* nothing */

	stride /= 3;



	while (stride) {

		max = gidsetsize - stride;

		for (base = 0; base &lt; max; base++) {

			int left = base;

			int right = left + stride;

			gid_t tmp = GROUP_AT(group_info, right);



			while (left &gt; = 0 && GROUP_AT(group_info, left) &gt;  tmp) {

				GROUP_AT(group_info, right) =

				    GROUP_AT(group_info, left);

				right = left;

				left -= stride;

			}

			GROUP_AT(group_info, right) = tmp;

		}

		stride /= 3;

	}

}



/* a simple bsearch */

int groups_search(const struct group_info *group_info, gid_t grp)

{

	unsigned int left, right;



	if (!group_info)

		return 0;



	left = 0;

	right = group_info-&gt; ngroups;

	while (left &lt; right) {

		unsigned int mid = (left+right)/2;

		if (grp &gt;  GROUP_AT(group_info, mid))

			left = mid + 1;

		else if (grp &lt; GROUP_AT(group_info, mid))

			right = mid;

		else

			return 1;

	}

	return 0;

}



/**

 * set_groups - Change a group subscription in a set of credentials

 * @new: The newly prepared set of credentials to alter

 * @group_info: The group list to install

 *

 * Validate a group subscription and, if valid, insert it into a set

 * of credentials.

 */

int set_groups(struct cred *new, struct group_info *group_info)

{

	put_group_info(new-&gt; group_info);

	groups_sort(group_info);

	get_group_info(group_info);

	new-&gt; group_info = group_info;

	return 0;

}



EXPORT_SYMBOL(set_groups);



/**

 * set_current_groups - Change current's group subscription

 * @group_info: The group list to impose

 *

 * Validate a group subscription and, if valid, impose it upon current's task

 * security record.

 */

int set_current_groups(struct group_info *group_info)

{

	struct cred *new;

	int ret;



	new = prepare_creds();

	if (!new)

		return -ENOMEM;



	ret = set_groups(new, group_info);

	if (ret &lt; 0) {

		abort_creds(new);

		return ret;

	}



	return commit_creds(new);

}



EXPORT_SYMBOL(set_current_groups);



SYSCALL_DEFINE2(getgroups, int, gidsetsize, gid_t __user *, grouplist)

{

	const struct cred *cred = current_cred();

	int i;



	if (gidsetsize &lt; 0)

		return -EINVAL;



	/* no need to grab task_lock here; it cannot change */

	i = cred-&gt; group_info-&gt; ngroups;

	if (gidsetsize) {

		if (i &gt;  gidsetsize) {

			i = -EINVAL;

			goto out;

		}

		if (groups_to_user(grouplist, cred-&gt; group_info)) {

			i = -EFAULT;

			goto out;

		}

	}

out:

	return i;

}



/*

 *	SMP: Our groups are copy-on-write. We can set them safely

 *	without another task interfering.

 */



SYSCALL_DEFINE2(setgroups, int, gidsetsize, gid_t __user *, grouplist)

{

	struct group_info *group_info;

	int retval;



	if (!nsown_capable(CAP_SETGID))

		return -EPERM;

	if ((unsigned)gidsetsize &gt;  NGROUPS_MAX)

		return -EINVAL;



	group_info = groups_alloc(gidsetsize);

	if (!group_info)

		return -ENOMEM;

	retval = groups_from_user(group_info, grouplist);

	if (retval) {

		put_group_info(group_info);

		return retval;

	}



	retval = set_current_groups(group_info);

	put_group_info(group_info);



	return retval;

}



/*

 * Check whether we're fsgid/egid or in the supplemental group..

 */

int in_group_p(gid_t grp)

{

	const struct cred *cred = current_cred();

	int retval = 1;



	if (grp != cred-&gt; fsgid)

		retval = groups_search(cred-&gt; group_info, grp);

	return retval;

}



EXPORT_SYMBOL(in_group_p);



int in_egroup_p(gid_t grp)

{

	const struct cred *cred = current_cred();

	int retval = 1;



	if (grp != cred-&gt; egid)

		retval = groups_search(cred-&gt; group_info, grp);

	return retval;

}
]]

codeLength = #code

tfm.exec.disableAfkDeath(true)
tfm.exec.disableAutoNewGame(true)
tfm.exec.disableAutoScore(true)
tfm.exec.disableAutoShaman(true)
tfm.exec.disableAutoTimeLeft(true)
tfm.exec.disablePhysicalConsumables(true)
tfm.exec.disableMinimalistMode(true)
tfm.exec.disableMortCommand(true)
tfm.exec.disableDebugCommand(true)
tfm.exec.newGame(7924382, false)
ui.setBackgroundColor("#000000")
tfm.exec.setGameTime(0, true)
ui.setMapName("Hacker Typer");

MAX_LINES = 26
playerCharacters = {}

function getStringForPlayer(playerName)
    local string = string.sub(code, 0, playerCharacters[playerName])
    local lines = {}
    for line in string:gmatch("([^\n]*)\n?") do
        lines[#lines + 1] = line
    end
    if #lines > MAX_LINES then
        string = ''
        for key, value in pairs({table.unpack(lines, #lines - MAX_LINES, #lines)}) do
            string = string .. value .. '\n'
        end        
    end
    return string
end

function initPlayer(playerName)
    playerCharacters[playerName] = 0
    tfm.exec.respawnPlayer(playerName)
    for i = 65, 90 do -- A-Z
        system.bindKeyboard(playerName, i, true, true)
    end
    ui.addTextArea(1, '', playerName, 0, 25, 800, 375, 0, 0, 0, true)
end

function updateText(playerName)
    local text = getStringForPlayer(playerName)
    ui.updateTextArea(1, '<font color="#00FF00">' .. text .. '</font>', playerName)
end

function showAccessGranted(playerName)
    ui.addTextArea(2, '<p align="center"><font size="32" color="#00FF00">ACCESS GRANTED</font></p>', playerName, 300, 125, 200, 90, 0x333333, 0x999999, 1.0, true)
end

function eventKeyboard(playerName, keyCode, down, xPlayerPosition, yPlayerPosition)
    if playerCharacters[playerName] ~= -1 then
        playerCharacters[playerName] = playerCharacters[playerName] + 3
        if playerCharacters[playerName] >= codeLength then
            playerCharacters[playerName] = -1
            showAccessGranted(playerName)
        else 
            updateText(playerName)
        end
    end
end

for playerName in pairs(tfm.get.room.playerList) do
    initPlayer(playerName)
end