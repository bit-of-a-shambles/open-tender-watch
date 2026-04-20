class AddStartAndEndDateToEntityPersonRoles < ActiveRecord::Migration[8.0]
  def change
    add_column :entity_person_roles, :start_date, :date
    add_column :entity_person_roles, :end_date, :date

    # Replace old unique index to allow multiple historical stints per person
    remove_index :entity_person_roles,
                 name: :index_entity_person_roles_unique_active_state
    add_index :entity_person_roles,
              %i[entity_id person_id role_type source_name start_date],
              unique: true,
              name: :index_entity_person_roles_unique_stint
  end
end
