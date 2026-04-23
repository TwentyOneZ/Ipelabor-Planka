/*!
 * Copyright (c) 2024 PLANKA Software GmbH
 * Licensed under the Fair Use License: https://github.com/plankanban/planka/blob/master/LICENSE.md
 */

import React, { useCallback } from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { Menu } from 'semantic-ui-react';

import UserAvatar from '../users/UserAvatar';

import styles from '../board-memberships/PureBoardMembershipsStep/Item.module.scss';

const CardMembershipsStepItem = React.memo(
  ({ userId, name, isActive, onUserSelect, onUserDeselect }) => {
    const handleToggleClick = useCallback(() => {
      if (isActive) {
        if (onUserDeselect) {
          onUserDeselect(userId);
        }

        return;
      }

      onUserSelect(userId);
    }, [isActive, onUserDeselect, onUserSelect, userId]);

    return (
      <Menu.Item
        active={isActive}
        className={classNames(styles.menuItem, isActive && styles.menuItemActive)}
        onClick={handleToggleClick}
      >
        <span className={styles.user}>
          <UserAvatar id={userId} />
        </span>
        <div className={classNames(styles.menuItemText, isActive && styles.menuItemTextActive)}>
          {name}
        </div>
      </Menu.Item>
    );
  },
);

CardMembershipsStepItem.propTypes = {
  userId: PropTypes.string.isRequired,
  name: PropTypes.string.isRequired,
  isActive: PropTypes.bool.isRequired,
  onUserSelect: PropTypes.func.isRequired,
  onUserDeselect: PropTypes.func,
};

CardMembershipsStepItem.defaultProps = {
  onUserDeselect: undefined,
};

export default CardMembershipsStepItem;
